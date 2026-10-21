package main

import (
	"context"

	"connectrpc.com/connect"
	"github.com/google/uuid"
)

func (s *alertsServer) recordInteraction(ctx context.Context, user uuid.UUID, in alertRequest) error {
	id, err := uuid.Parse(in.ID)
	if err != nil {
		return alertError(connect.CodeInvalidArgument, "Invalid alert ID.")
	}
	eventID, err := uuid.Parse(in.InteractionID)
	if err != nil {
		return alertError(connect.CodeInvalidArgument, "Invalid interaction ID.")
	}
	if in.Source != "notification" && in.Source != "alerts_tab" && in.Source != "creation" && in.Source != "search" && in.Source != "search_history" {
		return alertError(connect.CodeInvalidArgument, "Invalid interaction source.")
	}
	if (in.Event != "alert_opened" && in.Event != "listing_opened") || (in.Event == "listing_opened") != (in.ListingID != "") {
		return alertError(connect.CodeInvalidArgument, "Invalid interaction event.")
	}
	var notification *uuid.UUID
	if in.NotificationID != "" {
		parsed, e := uuid.Parse(in.NotificationID)
		if e != nil || (in.Source != "notification" && in.Source != "alerts_tab") {
			return alertError(connect.CodeInvalidArgument, "Invalid notification ID.")
		}
		notification = &parsed
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var exists uuid.UUID
	if err = tx.QueryRow(ctx, `SELECT id FROM user_listing_alerts WHERE id=$1 AND user_id=$2 FOR UPDATE`, id, user).Scan(&exists); err != nil {
		return alertNotFound(err)
	}
	if notification != nil {
		if err = tx.QueryRow(ctx, `SELECT id FROM listing_alert_notification_outbox WHERE id=$1 AND alert_id=$2 AND ($3='' OR $3=ANY(listing_ids))`, notification, id, in.ListingID).Scan(&exists); err != nil {
			return alertNotFound(err)
		}
	}
	if in.Event == "listing_opened" {
		tag, e := tx.Exec(ctx, `UPDATE listing_alert_listings SET viewed_at=COALESCE(viewed_at,clock_timestamp()) WHERE alert_id=$1 AND listing_id=$2 AND matched`, id, in.ListingID)
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return alertError(connect.CodeNotFound, "Match not found.")
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO listing_alert_interactions(id,alert_id,notification_id,listing_id,kind,source) VALUES($1,$2,$3,NULLIF($4,''),$5,$6) ON CONFLICT(id) DO NOTHING`, eventID, id, notification, in.ListingID, in.Event, in.Source)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}
