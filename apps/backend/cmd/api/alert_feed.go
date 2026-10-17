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

type alertNotificationGroup struct {
	SeenAt        *time.Time      `json:"seenAt"`
	ID            string          `json:"id"`
	AlertID       string          `json:"alertID"`
	Query         string          `json:"query"`
	CreatedAt     time.Time       `json:"createdAt"`
	CreatedCursor string          `json:"createdCursor"`
	MatchCount    int             `json:"matchCount"`
	UnreadCount   int             `json:"unreadCount"`
	Previews      json.RawMessage `json:"previews"`
}

func (s *alertsServer) notificationFeed(ctx context.Context, user uuid.UUID, in alertRequest) (any, error) {
	beforeID := uuid.Nil
	if in.Before != nil {
		var err error
		beforeID, err = uuid.Parse(in.BeforeID)
		if err != nil {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid notification cursor.")
		}
	}
	rows, err := s.pool.Query(ctx, `SELECT n.id,a.id,a.query,n.created_at,
 (SELECT min(i.created_at) FROM listing_alert_interactions i WHERE i.notification_id=n.id AND i.kind IN ('alert_opened','listing_opened')),
 (SELECT count(*) FROM listing_alert_listings l WHERE l.alert_id=a.id AND l.matched AND l.listing_id=ANY(n.listing_ids)),
 (SELECT count(*) FROM listing_alert_listings l WHERE l.alert_id=a.id AND l.matched AND l.viewed_at IS NULL AND l.listing_id=ANY(n.listing_ids)),
 (SELECT coalesce(jsonb_agg(p.listing ORDER BY p.matched_at DESC,p.listing_id DESC),'[]'::jsonb) FROM (
 SELECT l.listing,l.matched_at,l.listing_id FROM listing_alert_listings l WHERE l.alert_id=a.id AND l.matched AND l.listing_id=ANY(n.listing_ids)
 ORDER BY l.matched_at DESC,l.listing_id DESC LIMIT 4) p)
 FROM listing_alert_notification_outbox n JOIN user_listing_alerts a ON a.id=n.alert_id
 WHERE a.user_id=$1 AND ($2::timestamptz IS NULL OR (n.created_at,n.id)<($2,$3))
 ORDER BY n.created_at DESC,n.id DESC LIMIT 50`, user, in.Before, beforeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	groups := []alertNotificationGroup{}
	for rows.Next() {
		var group alertNotificationGroup
		if err = rows.Scan(&group.ID, &group.AlertID, &group.Query, &group.CreatedAt, &group.SeenAt, &group.MatchCount, &group.UnreadCount, &group.Previews); err != nil {
			return nil, err
		}
		group.CreatedCursor = group.CreatedAt.UTC().Format(time.RFC3339Nano)
		groups = append(groups, group)
	}
	return map[string]any{"groups": groups}, rows.Err()
}

type alertNotificationDetails struct {
	ID         string    `json:"id"`
	Query      string    `json:"query"`
	CreatedAt  time.Time `json:"createdAt"`
	MatchCount int       `json:"matchCount"`
}

// A notification's individual listings form the inbox. Its cursor includes the
// listing ID so a notification larger than one page cannot lose any rows.
type alertInboxItem struct {
	NotificationID string          `json:"notificationID"`
	AlertID        string          `json:"alertID"`
	Query          string          `json:"query"`
	Listing        json.RawMessage `json:"listing"`
	CreatedAt      time.Time       `json:"createdAt"`
	CreatedCursor  string          `json:"createdCursor"`
	ViewedAt       *time.Time      `json:"viewedAt"`
	SavedAt        *time.Time      `json:"savedAt"`
}

func (s *alertsServer) inbox(ctx context.Context, user uuid.UUID, in alertRequest) (any, error) {
	if in.Filter != "" && in.Filter != "all" && in.Filter != "unread" && in.Filter != "saved" {
		return nil, alertError(connect.CodeInvalidArgument, "Invalid inbox filter.")
	}
	beforeNotification := uuid.Nil
	if in.Before != nil {
		var err error
		beforeNotification, err = uuid.Parse(in.NotificationID)
		if err != nil || !alertListingID.MatchString(in.BeforeID) {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid inbox cursor.")
		}
	}
	rows, err := s.pool.Query(ctx, `SELECT n.id,a.id,a.query,l.listing,n.created_at,l.viewed_at,l.saved_at
 FROM listing_alert_notification_outbox n JOIN user_listing_alerts a ON a.id=n.alert_id
 JOIN listing_alert_listings l ON l.alert_id=a.id AND l.matched AND l.listing_id=ANY(n.listing_ids)
 WHERE a.user_id=$1 AND ($2::timestamptz IS NULL OR (n.created_at,n.id,l.listing_id)<($2,$3,$4))
 AND ($5!='unread' OR l.viewed_at IS NULL)
 AND ($5!='saved' OR EXISTS (SELECT 1 FROM saved_listings s JOIN listings listing ON listing.id=s.listing_id WHERE s.user_id=$1 AND listing.facebook_listing_id=l.listing_id))
 ORDER BY n.created_at DESC,n.id DESC,l.listing_id DESC LIMIT 50`, user, in.Before, beforeNotification, in.BeforeID, in.Filter)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []alertInboxItem{}
	for rows.Next() {
		var item alertInboxItem
		if err = rows.Scan(&item.NotificationID, &item.AlertID, &item.Query, &item.Listing, &item.CreatedAt, &item.ViewedAt, &item.SavedAt); err != nil {
			return nil, err
		}
		item.CreatedCursor = item.CreatedAt.UTC().Format(time.RFC3339Nano)
		items = append(items, item)
	}
	return map[string]any{"items": items}, rows.Err()
}
