package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/push"
	"github.com/google/uuid"
	"go.uber.org/zap"
)

func (s *alertsServer) fetchWork(ctx context.Context, user, session uuid.UUID, in alertRequest) (any, error) {
	if !slices.Contains([]string{"", "foreground", "background_push"}, in.Trigger) ||
		(in.Trigger == "background_push") != (in.FetchAttemptID != "") {
		return nil, alertError(connect.CodeInvalidArgument, "Invalid fetch trigger.")
	}
	var attemptID *uuid.UUID
	if in.FetchAttemptID != "" {
		id, err := uuid.Parse(in.FetchAttemptID)
		if err != nil {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid fetch attempt.")
		}
		attemptID = &id
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	device, err := s.eligibleDevice(ctx, tx, session)
	if err != nil {
		return nil, err
	}
	var checkID *uuid.UUID
	if attemptID != nil {
		var id uuid.UUID
		err = tx.QueryRow(ctx, `SELECT f.check_id FROM listing_alert_background_fetch_attempts f JOIN listing_alert_check_runs c ON c.id=f.check_id JOIN user_listing_alerts a ON a.id=c.alert_id WHERE f.id=$1 AND f.device_id=$2 AND a.user_id=$3 AND f.trigger='background_push'`, attemptID, device, user).Scan(&id)
		if err != nil {
			return nil, alertNotFound(err)
		}
		checkID = &id
	}
	rows, err := tx.Query(ctx, `SELECT c.id,a.id,a.query,a.location,c.cursor,c.facebook_actor,c.page_number FROM listing_alert_check_runs c JOIN user_listing_alerts a ON a.id=c.alert_id WHERE a.user_id=$1 AND a.device_id=$2 AND NOT a.paused AND c.completed_at IS NULL AND NOT c.scan_complete AND ($3::uuid IS NULL OR c.id=$3) ORDER BY c.created_at LIMIT 3 FOR UPDATE OF a,c`, user, device, checkID)
	if err != nil {
		return nil, err
	}
	work := []alertWork{}
	for rows.Next() {
		var v alertWork
		var location []byte
		if err = rows.Scan(&v.ID, &v.AlertID, &v.Query, &location, &v.Cursor, &v.Actor, &v.PageNumber); err != nil {
			rows.Close()
			return nil, err
		}
		if err = json.Unmarshal(location, &v.Location); err != nil {
			rows.Close()
			return nil, err
		}
		v.SearchOptions = s.searchOptions
		work = append(work, v)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	for i := range work {
		v := &work[i]
		if in.Trigger == "" {
			continue
		} // Older apps cannot report a fetch-attempt ID.
		if attemptID != nil {
			v.FetchAttemptID = attemptID.String()
		} else {
			err = tx.QueryRow(ctx, `INSERT INTO listing_alert_background_fetch_attempts(check_id,device_id,trigger) VALUES($1,$2,'foreground') RETURNING id`, v.ID, device).Scan(&v.FetchAttemptID)
			if err != nil {
				return nil, err
			}
		}
		snapshot, _ := json.Marshal(v)
		var saved []byte
		err = tx.QueryRow(ctx, `UPDATE listing_alert_background_fetch_attempts SET work_requested_at=COALESCE(work_requested_at,clock_timestamp()),search_request=COALESCE(search_request,$2) WHERE id=$1 RETURNING search_request`, v.FetchAttemptID, snapshot).Scan(&saved)
		if err != nil {
			return nil, err
		}
		if err = json.Unmarshal(saved, v); err != nil {
			return nil, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return map[string]any{"work": work}, nil
}

func (s *alertsServer) recordFetchEvent(ctx context.Context, user, session uuid.UUID, in alertRequest) error {
	id, err := uuid.Parse(in.FetchAttemptID)
	if err != nil {
		return alertError(connect.CodeInvalidArgument, "Invalid fetch attempt.")
	}
	if !slices.Contains([]string{"acknowledged", "search_started", "failed"}, in.Event) {
		return alertError(connect.CodeInvalidArgument, "Invalid fetch event.")
	}
	if in.Event == "failed" && (!slices.Contains([]string{"eligibility", "work", "search", "upload", "background"}, in.FailureStage) ||
		!slices.Contains([]string{"facebook_disconnected", "notifications_disabled", "facebook_changed", "request_failed", "cancelled", "deadline_exceeded", "already_running", "no_pending_work", "unsupported_search", "invalid_facebook_response", "facebook_blocked", "search_paused", "network_timeout", "network_error", "invalid_server_response"}, in.FailureCode)) {
		return alertError(connect.CodeInvalidArgument, "Invalid fetch failure.")
	}
	// Receipt and failure reports must work even when Facebook or notifications are no longer enabled.
	tag, err := s.pool.Exec(ctx, `UPDATE listing_alert_background_fetch_attempts f SET
        acknowledged_at=CASE WHEN $4='acknowledged' AND f.trigger='background_push' THEN COALESCE(f.acknowledged_at,clock_timestamp()) ELSE f.acknowledged_at END,
        search_started_at=CASE WHEN $4='search_started' THEN COALESCE(f.search_started_at,clock_timestamp()) ELSE f.search_started_at END,
        failure_at=CASE WHEN $4='failed' AND f.upload_received_at IS NULL THEN COALESCE(f.failure_at,clock_timestamp()) ELSE f.failure_at END,
        failure_stage=CASE WHEN $4='failed' AND f.upload_received_at IS NULL THEN COALESCE(f.failure_stage,$5) ELSE f.failure_stage END,
        failure_code=CASE WHEN $4='failed' AND f.upload_received_at IS NULL THEN COALESCE(f.failure_code,$6) ELSE f.failure_code END
        FROM listing_alert_check_runs c,user_listing_alerts a,user_sessions us
        WHERE f.id=$1 AND c.id=f.check_id AND a.id=c.alert_id AND a.user_id=$2
        AND us.id=$3 AND us.user_id=$2 AND us.device_id=f.device_id AND us.revoked_at IS NULL AND us.refresh_token_expires_at>now()`, id, user, session, in.Event, in.FailureStage, in.FailureCode)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return alertError(connect.CodeNotFound, "Fetch attempt not found.")
	}
	s.logger.Info("listing alert fetch event", zap.String("fetch_attempt_id", id.String()), zap.String("event", in.Event), zap.String("failure_stage", in.FailureStage), zap.String("failure_code", in.FailureCode))
	return nil
}

func alertPushError(err error) string {
	var rejection *push.Error
	if errors.As(err, &rejection) {
		return fmt.Sprintf("apns_%d_%s", rejection.Status, rejection.Reason)
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "transport_error"
}

func (s *alertsServer) recordBackgroundPushResult(ctx context.Context, id uuid.UUID, sendErr error) error {
	// Preserve the send outcome if the worker deadline expired during the APNs request.
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	var code *string
	if sendErr != nil {
		value := alertPushError(sendErr)
		code = &value
	}
	_, err := s.pool.Exec(cleanup, `UPDATE listing_alert_background_fetch_attempts SET send_finished_at=clock_timestamp(),apns_accepted_at=CASE WHEN $2::text IS NULL THEN clock_timestamp() END,send_error=$2 WHERE id=$1`, id, code)
	s.logger.Info("listing alert background push", zap.String("fetch_attempt_id", id.String()), zap.Bool("apns_accepted", sendErr == nil), zap.Any("send_error", code))
	return err
}
