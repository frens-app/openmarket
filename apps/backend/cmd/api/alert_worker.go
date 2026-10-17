package main

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"frens.lol/openmarket/backend/pkg/llm"
	"frens.lol/openmarket/backend/pkg/push"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"go.uber.org/zap"
)

func (s *alertsServer) run(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tickCtx, cancel := context.WithTimeout(ctx, 50*time.Second)
			if err := s.tick(tickCtx, interval); err != nil && !errors.Is(err, context.Canceled) {
				s.logger.Warn("listing alert worker", zap.Error(err))
			}
			cancel()
		}
	}
}

func (s *alertsServer) tick(ctx context.Context, interval time.Duration) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	var locked bool
	if err = conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(724190032)`).Scan(&locked); err != nil || !locked {
		return err
	}
	// The connection owns the lock; releasing a pooled connection alone would retain it.
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, e := conn.Exec(cleanup, `SELECT pg_advisory_unlock(724190032)`); e != nil {
			_ = conn.Conn().Close(cleanup)
		}
	}()
	if err = s.dispatch(ctx, interval); err != nil {
		s.logger.Warn("dispatch alert", zap.Error(err))
	}
	if err = s.evaluateBatch(ctx); err != nil {
		s.logger.Warn("evaluate alert", zap.Error(err))
	}
	return s.notifyMatches(ctx)
}

const eligibleAlertDevice = `d.facebook_connected AND d.notification_permission_status='ENABLED' AND d.push_token IS NOT NULL AND EXISTS (SELECT 1 FROM user_sessions us WHERE us.device_id=d.id AND us.revoked_at IS NULL AND us.refresh_token_expires_at>now())`

func (s *alertsServer) dispatch(ctx context.Context, interval time.Duration) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `UPDATE listing_alert_worker_clock SET next_dispatch_at=now()+$1*interval '1 second' WHERE id=1 AND next_dispatch_at<=now()`, interval.Seconds())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return nil
	}
	// SKIP LOCKED keeps account edits and uploads from stalling the scheduler.
	_, err = tx.Exec(ctx, `INSERT INTO listing_alert_check_runs(alert_id)
 SELECT a.id FROM user_listing_alerts a JOIN user_devices d ON d.id=a.device_id JOIN users u ON u.id=a.user_id
 WHERE NOT a.paused AND u.deleted_at IS NULL AND a.next_check_at<=now()
 AND `+eligibleAlertDevice+`
 AND NOT EXISTS(SELECT 1 FROM listing_alert_check_runs c WHERE c.alert_id=a.id AND c.completed_at IS NULL)
 ORDER BY a.next_check_at,a.last_checked_at NULLS FIRST,a.created_at LIMIT 1 FOR UPDATE OF a SKIP LOCKED
 ON CONFLICT DO NOTHING`)
	if err != nil {
		return err
	}
	var checkID, alertID, deviceID uuid.UUID
	var token string
	err = tx.QueryRow(ctx, `SELECT c.id,a.id,d.id,d.push_token FROM listing_alert_check_runs c JOIN user_listing_alerts a ON a.id=c.alert_id JOIN user_devices d ON d.id=a.device_id
 WHERE NOT a.paused AND c.completed_at IS NULL AND NOT c.scan_complete AND c.next_push_at<=now() AND `+eligibleAlertDevice+`
 AND NOT EXISTS(SELECT 1 FROM listing_alert_check_runs other JOIN user_listing_alerts oa ON oa.id=other.alert_id WHERE oa.device_id=d.id AND other.last_push_at>now()-interval '30 minutes')
 ORDER BY c.next_push_at,c.created_at LIMIT 1 FOR UPDATE OF c SKIP LOCKED`).Scan(&checkID, &alertID, &deviceID, &token)
	if errors.Is(err, pgx.ErrNoRows) {
		return tx.Commit(ctx)
	}
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE listing_alert_check_runs SET push_attempts=push_attempts+1,last_push_at=now(),next_push_at=now()+CASE WHEN (push_attempts+1)%3=0 THEN interval '22 hours' ELSE interval '1 hour' END WHERE id=$1`, checkID)
	if err != nil {
		return err
	}
	var fetchAttemptID uuid.UUID
	err = tx.QueryRow(ctx, `INSERT INTO listing_alert_background_fetch_attempts(check_id,device_id,trigger,send_started_at) VALUES($1,$2,'background_push',clock_timestamp()) RETURNING id`, checkID, deviceID).Scan(&fetchAttemptID)
	if err != nil {
		return err
	}
	if err = tx.Commit(ctx); err != nil {
		return err
	}
	err = s.push.Send(ctx, token, "check-"+alertID.String(), true, map[string]any{"aps": map[string]any{"content-available": 1}, "kind": "price_alert_check", "alert_id": alertID.String(), "check_id": checkID.String(), "fetch_attempt_id": fetchAttemptID.String()})
	s.invalidateToken(ctx, deviceID, token, err)
	if recordErr := s.recordBackgroundPushResult(ctx, fetchAttemptID, err); recordErr != nil {
		return recordErr
	}
	if err != nil {
		return errors.New(alertPushError(err))
	}
	return nil
}

func (s *alertsServer) evaluateBatch(ctx context.Context) error {
	var checkID, alertID, userID uuid.UUID
	var query string
	err := s.pool.QueryRow(ctx, `SELECT c.id,a.id,a.user_id,a.query FROM listing_alert_check_runs c JOIN user_listing_alerts a ON a.id=c.alert_id JOIN users u ON u.id=a.user_id WHERE NOT a.paused AND u.deleted_at IS NULL AND c.completed_at IS NULL AND c.evaluation_after<=now() AND (c.scan_complete OR EXISTS(SELECT 1 FROM listing_alert_listings l WHERE l.check_id=c.id AND l.checked_at IS NULL)) ORDER BY c.evaluation_after,c.created_at LIMIT 1`).Scan(&checkID, &alertID, &userID, &query)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	rows, err := s.pool.Query(ctx, `SELECT listing FROM listing_alert_listings WHERE check_id=$1 AND checked_at IS NULL ORDER BY listing_id LIMIT 30`, checkID)
	if err != nil {
		return err
	}
	in := llm.EvaluationInput{Target: llm.ComparisonItem{Title: query}, Requirements: true}
	for rows.Next() {
		var raw []byte
		var listing alertListing
		if err = rows.Scan(&raw); err != nil {
			rows.Close()
			return err
		}
		if err = json.Unmarshal(raw, &listing); err != nil {
			rows.Close()
			return err
		}
		in.Candidates = append(in.Candidates, llm.Candidate{ID: listing.ID, Item: llm.ComparisonItem{Title: listing.Title, Description: "Price: " + listing.PriceText + ". " + listing.Description, Condition: listing.Condition}})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	var decisions []llm.Decision
	if len(in.Candidates) > 0 {
		if _, err = s.pool.Exec(ctx, `UPDATE listing_alert_check_runs SET evaluation_started_at=COALESCE(evaluation_started_at,clock_timestamp()) WHERE id=$1`, checkID); err != nil {
			return err
		}
		decisions, err = s.evaluator.Evaluate(ctx, llm.Subject{UserID: userID}, in)
		if err != nil {
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			_, updateErr := s.pool.Exec(cleanup, `UPDATE listing_alert_check_runs SET evaluation_after=now()+interval '1 hour',evaluation_error_at=clock_timestamp(),evaluation_error_code='evaluator_failed' WHERE id=$1`, checkID)
			cancel()
			s.logger.Warn("listing alert evaluation failed", zap.String("check_id", checkID.String()), zap.Error(err))
			if updateErr != nil {
				return updateErr
			}
			return err
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var active uuid.UUID
	err = tx.QueryRow(ctx, `SELECT id FROM user_listing_alerts WHERE id=$1 AND NOT paused FOR UPDATE`, alertID).Scan(&active)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, d := range decisions {
		_, e := tx.Exec(ctx, `UPDATE listing_alert_listings SET checked_at=now(),matched=$3,probability=$4,matched_at=CASE WHEN $3 THEN now() END WHERE alert_id=$1 AND listing_id=$2 AND checked_at IS NULL`, alertID, d.ID, d.UseInComparison, d.Probability)
		if e != nil {
			return e
		}
	}
	var finished bool
	err = tx.QueryRow(ctx, `SELECT scan_complete AND NOT EXISTS(SELECT 1 FROM listing_alert_listings WHERE check_id=$1 AND checked_at IS NULL) FROM listing_alert_check_runs WHERE id=$1`, checkID).Scan(&finished)
	if err != nil {
		return err
	}
	if finished {
		_, err = tx.Exec(ctx, `INSERT INTO listing_alert_notification_outbox(alert_id,check_id,listing_ids)
            SELECT $1,$2,array_agg(listing_id) FROM listing_alert_listings
            WHERE check_id=$2 AND matched HAVING count(*)>0 ON CONFLICT(check_id) DO NOTHING`, alertID, checkID)
		if err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE listing_alert_check_runs SET completed_at=now() WHERE id=$1`, checkID); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE user_listing_alerts SET last_checked_at=now(),next_check_at=next_listing_alert_check_time(now(),alert_hour::integer,alert_minute::integer,time_zone) WHERE id=$1`, alertID)
	} else {
		_, err = tx.Exec(ctx, `UPDATE listing_alert_check_runs SET evaluation_after=now() WHERE id=$1`, checkID)
	}
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *alertsServer) notifyMatches(ctx context.Context) error {
	var notificationID, alertID, deviceID uuid.UUID
	var token, query string
	var ids []string
	err := s.pool.QueryRow(ctx, `WITH next AS (
        SELECT n.id,a.id AS alert_id,d.id AS device_id,d.push_token,a.query,n.listing_ids
        FROM listing_alert_notification_outbox n JOIN user_listing_alerts a ON a.id=n.alert_id JOIN user_devices d ON d.id=a.device_id
        WHERE n.send_started_at IS NULL AND NOT a.paused AND `+eligibleAlertDevice+`
        ORDER BY n.created_at LIMIT 1 FOR UPDATE OF n SKIP LOCKED
    ) UPDATE listing_alert_notification_outbox n SET send_started_at=clock_timestamp()
      FROM next WHERE n.id=next.id RETURNING n.id,next.alert_id,next.device_id,next.push_token,next.query,next.listing_ids`).Scan(&notificationID, &alertID, &deviceID, &token, &query, &ids)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}

	err = s.push.Send(ctx, token, "match-"+notificationID.String(), false, map[string]any{"aps": map[string]any{"alert": map[string]string{"title": "New listing alert matches", "body": "We found listings for “" + query + "”."}, "sound": "default", "thread-id": alertID.String()}, "kind": "price_alert_match", "alert_id": alertID.String()})
	s.invalidateToken(ctx, deviceID, token, err)
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	ctx = cleanup
	var code *string
	if err != nil {
		value := alertPushError(err)
		code = &value
	}
	if _, recordErr := s.pool.Exec(ctx, `UPDATE listing_alert_notification_outbox SET send_finished_at=clock_timestamp(),send_error=$2,sent_at=CASE WHEN $2::text IS NULL THEN clock_timestamp() ELSE sent_at END WHERE id=$1`, notificationID, code); recordErr != nil {
		return recordErr
	}
	s.logger.Info("listing alert match notification", zap.String("notification_id", notificationID.String()), zap.String("alert_id", alertID.String()), zap.Bool("apns_accepted", err == nil), zap.Any("send_error", code))
	if err != nil {
		return errors.New(*code)
	}

	_, err = s.pool.Exec(ctx, `UPDATE listing_alert_listings SET notification_sent_at=COALESCE(notification_sent_at,now()) WHERE alert_id=$1 AND listing_id=ANY($2)`, alertID, ids)
	return err
}

func (s *alertsServer) invalidateToken(ctx context.Context, device uuid.UUID, token string, err error) {
	var rejected *push.Error
	if errors.As(err, &rejected) && rejected.InvalidToken() {
		if _, e := s.pool.Exec(ctx, `UPDATE user_devices SET push_token=NULL WHERE id=$1 AND push_token=$2`, device, token); e != nil {
			s.logger.Warn("clear invalid APNs token", zap.Error(e))
		}
	}
}
