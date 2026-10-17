package main

import (
	"context"
	"encoding/json"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
)

type alertFeedMatch struct {
	Listing       json.RawMessage `json:"listing"`
	MatchedAt     time.Time       `json:"matchedAt"`
	MatchedCursor string          `json:"matchedCursor"`
	ViewedAt      *time.Time      `json:"viewedAt"`
}
type alertFeedItem struct {
	AlertID string         `json:"alertID"`
	Query   string         `json:"query"`
	Match   alertFeedMatch `json:"match"`
}

func (s *alertsServer) feed(ctx context.Context, user uuid.UUID, in alertRequest) (any, error) {
	beforeAlert := uuid.Nil
	if in.Before != nil {
		var err error
		beforeAlert, err = uuid.Parse(in.BeforeAlertID)
		if err != nil || !alertListingID.MatchString(in.BeforeID) {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid feed cursor.")
		}
	}
	rows, err := s.pool.Query(ctx, `SELECT a.id,a.query,l.listing,l.matched_at,l.viewed_at
 FROM user_listing_alerts a JOIN listing_alert_listings l ON l.alert_id=a.id
 WHERE a.user_id=$1 AND l.matched AND ($2::timestamptz IS NULL OR (l.matched_at,l.alert_id,l.listing_id)<($2,$3,$4))
 ORDER BY l.matched_at DESC,l.alert_id DESC,l.listing_id DESC LIMIT 50`, user, in.Before, beforeAlert, in.BeforeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []alertFeedItem{}
	for rows.Next() {
		var item alertFeedItem
		if err = rows.Scan(&item.AlertID, &item.Query, &item.Match.Listing, &item.Match.MatchedAt, &item.Match.ViewedAt); err != nil {
			return nil, err
		}
		item.Match.MatchedCursor = item.Match.MatchedAt.UTC().Format(time.RFC3339Nano)
		items = append(items, item)
	}
	return map[string]any{"items": items}, rows.Err()
}
