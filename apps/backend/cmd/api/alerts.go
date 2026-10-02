package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"regexp"
	"strings"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/llm"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

type alertPushSender interface {
	Send(context.Context, string, string, bool, map[string]any) error
}
type alertEvaluator interface {
	Evaluate(context.Context, llm.Subject, llm.EvaluationInput) ([]llm.Decision, error)
}
type alertsServer struct {
	pool      *pgxpool.Pool
	queries   *db.Queries
	jwtSecret string
	evaluator alertEvaluator
	push      alertPushSender
	logger    *zap.Logger
}
type alertLocation struct {
	CitySlug  string  `json:"citySlug"`
	Name      string  `json:"name"`
	RadiusKM  int     `json:"radiusKM"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}
type priceAlert struct {
	ID            string        `json:"id"`
	Query         string        `json:"query"`
	Location      alertLocation `json:"location"`
	CreatedAt     time.Time     `json:"createdAt"`
	AlertHour     int           `json:"alertHour"`
	NextCheckAt   time.Time     `json:"nextCheckAt"`
	LastCheckedAt *time.Time    `json:"lastCheckedAt"`
	Paused        bool          `json:"paused"`
	MatchCount    int           `json:"matchCount"`
	UnreadCount   int           `json:"unreadCount"`
}
type alertListing struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	PriceText    string `json:"priceText"`
	LocationText string `json:"locationText"`
	ThumbnailURL string `json:"thumbnailURL"`
	Description  string `json:"description"`
	Condition    string `json:"condition"`
}
type alertRequest struct {
	ID         string         `json:"id"`
	Query      string         `json:"query"`
	Location   alertLocation  `json:"location"`
	Paused     bool           `json:"paused"`
	CheckID    string         `json:"checkID"`
	PageNumber int            `json:"pageNumber"`
	Cursor     *string        `json:"cursor"`
	Actor      string         `json:"actor"`
	Complete   bool           `json:"complete"`
	Listings   []alertListing `json:"listings"`
	ListingIDs []string       `json:"listingIDs"`
	BeforeID   string         `json:"beforeID"`
	Before     *time.Time     `json:"before"`
}
type alertWork struct {
	ID         string        `json:"id"`
	AlertID    string        `json:"alertID"`
	Query      string        `json:"query"`
	Location   alertLocation `json:"location"`
	Cursor     *string       `json:"cursor"`
	Actor      *string       `json:"actor"`
	PageNumber int           `json:"pageNumber"`
}

func alertError(code connect.Code, message string) error {
	return connect.NewError(code, errors.New(message))
}

func (s *alertsServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", 405)
		return
	}
	ctx, err := authenticate(r.Context(), r.URL.Path, r.Header, s.jwtSecret, s.queries)
	var result any
	if err == nil {
		var in alertRequest
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512<<10))
		decoder.DisallowUnknownFields()
		if decodeErr := decoder.Decode(&in); decodeErr != nil {
			err = alertError(connect.CodeInvalidArgument, "Invalid alert request.")
		} else if decodeErr = decoder.Decode(&struct{}{}); decodeErr != io.EOF {
			err = alertError(connect.CodeInvalidArgument, "Invalid alert request.")
		} else {
			result, err = s.handle(ctx, strings.TrimPrefix(r.URL.Path, "/v1/price-alerts/"), in)
		}
	}
	if err != nil {
		status := 500
		message := "Couldn't complete the alert request."
		switch connect.CodeOf(err) {
		case connect.CodeUnauthenticated:
			status = 401
			message = "Your session ended. Sign in again."
		case connect.CodeInvalidArgument:
			status = 400
			message = err.(*connect.Error).Message()
		case connect.CodeFailedPrecondition:
			status = 412
			message = err.(*connect.Error).Message()
		case connect.CodeNotFound:
			status = 404
			message = "Alert or check no longer exists."
		case connect.CodeResourceExhausted:
			status = 429
			message = err.(*connect.Error).Message()
		case connect.CodeAborted:
			status = 409
			message = "The check changed. Refresh and try again."
		case connect.CodeUnavailable:
			status = 503
			message = "Price alerts are not configured yet."
		}
		if status == 500 {
			s.logger.Error("price alert request", zap.Error(err))
		}
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
		return
	}
	if result == nil {
		result = struct{}{}
	}
	_ = json.NewEncoder(w).Encode(result)
}

func (s *alertsServer) handle(ctx context.Context, action string, in alertRequest) (any, error) {
	userID, _ := auth.UserID(ctx)
	sessionID, _ := auth.SessionID(ctx)
	switch action {
	case "list":
		return s.list(ctx, userID)
	case "create":
		if s.push == nil || s.evaluator == nil {
			return nil, alertError(connect.CodeUnavailable, "Price alerts unavailable.")
		}
		in.Query = strings.TrimSpace(in.Query)
		if err := validateAlert(in); err != nil {
			return nil, err
		}
		tx, err := s.pool.Begin(ctx)
		if err != nil {
			return nil, err
		}
		defer tx.Rollback(ctx)
		// Serializing on the account also coordinates with soft deletion.
		var exists uuid.UUID
		if err = tx.QueryRow(ctx, `SELECT id FROM users WHERE id=$1 AND deleted_at IS NULL FOR UPDATE`, userID).Scan(&exists); err != nil {
			return nil, err
		}
		var count int
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM price_alerts WHERE user_id=$1`, userID).Scan(&count); err != nil {
			return nil, err
		}
		if count >= 3 {
			return nil, alertError(connect.CodeResourceExhausted, "You can have up to 3 alerts. Delete an alert to create another.")
		}
		device, err := s.eligibleDevice(ctx, tx, sessionID)
		if err != nil {
			return nil, err
		}
		var now time.Time
		if err = tx.QueryRow(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
			return nil, err
		}
		schedule := now.UTC().Round(time.Hour)
		location, _ := json.Marshal(in.Location)
		var id string
		err = tx.QueryRow(ctx, `INSERT INTO price_alerts(user_id,device_id,query,location,created_at,alert_hour,next_check_at) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id`, userID, device, in.Query, location, now, schedule.Hour(), schedule).Scan(&id)
		if err != nil {
			return nil, err
		}
		return map[string]string{"id": id}, tx.Commit(ctx)
	case "state", "delete":
		id, err := uuid.Parse(in.ID)
		if err != nil {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid alert ID.")
		}
		tx, err := s.pool.Begin(ctx)
		if err != nil {
			return nil, err
		}
		defer tx.Rollback(ctx)
		var owner uuid.UUID
		if err = tx.QueryRow(ctx, `SELECT user_id FROM price_alerts WHERE id=$1 AND user_id=$2 FOR UPDATE`, id, userID).Scan(&owner); err != nil {
			return nil, alertNotFound(err)
		}
		if action == "delete" {
			_, err = tx.Exec(ctx, `DELETE FROM price_alerts WHERE id=$1`, id)
		} else if in.Paused {
			_, err = tx.Exec(ctx, `UPDATE price_alerts SET paused=true WHERE id=$1`, id)
		} else {
			device, e := s.eligibleDevice(ctx, tx, sessionID)
			if e != nil {
				return nil, e
			}
			// A resumed alert binds to the current install; old device cursors cannot travel.
			_, err = tx.Exec(ctx, `UPDATE price_alert_checks SET cursor=NULL,facebook_actor=NULL,page_number=page_number+1,next_push_at=now(),push_attempts=0 WHERE alert_id=$1 AND completed_at IS NULL AND NOT scan_complete`, id)
			if err == nil {
				_, err = tx.Exec(ctx, `UPDATE price_alerts SET paused=false,device_id=$2 WHERE id=$1`, id, device)
			}
		}
		if err != nil {
			return nil, err
		}
		return nil, tx.Commit(ctx)
	case "work":
		device, err := s.eligibleDevice(ctx, s.pool, sessionID)
		if err != nil {
			return nil, err
		}
		rows, err := s.pool.Query(ctx, `SELECT c.id,a.id,a.query,a.location,c.cursor,c.facebook_actor,c.page_number FROM price_alert_checks c JOIN price_alerts a ON a.id=c.alert_id WHERE a.user_id=$1 AND a.device_id=$2 AND NOT a.paused AND c.completed_at IS NULL AND NOT c.scan_complete ORDER BY c.created_at LIMIT 3`, userID, device)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		work := []alertWork{}
		for rows.Next() {
			var v alertWork
			var location []byte
			if err = rows.Scan(&v.ID, &v.AlertID, &v.Query, &location, &v.Cursor, &v.Actor, &v.PageNumber); err != nil {
				return nil, err
			}
			if err = json.Unmarshal(location, &v.Location); err != nil {
				return nil, err
			}
			work = append(work, v)
		}
		return map[string]any{"work": work}, rows.Err()
	case "page":
		return nil, s.submitPage(ctx, userID, sessionID, in)
	case "matches":
		id, err := uuid.Parse(in.ID)
		if err != nil {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid alert ID.")
		}
		rows, err := s.pool.Query(ctx, `SELECT l.listing,l.matched_at,l.viewed_at FROM price_alert_listings l JOIN price_alerts a ON a.id=l.alert_id WHERE a.id=$1 AND a.user_id=$2 AND l.matched AND ($3::timestamptz IS NULL OR (l.matched_at,l.listing_id)<($3,$4)) ORDER BY l.matched_at DESC,l.listing_id DESC LIMIT 100`, id, userID, in.Before, in.BeforeID)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		matches := []any{}
		for rows.Next() {
			var raw json.RawMessage
			var matched time.Time
			var viewed *time.Time
			if err = rows.Scan(&raw, &matched, &viewed); err != nil {
				return nil, err
			}
			matches = append(matches, map[string]any{"listing": raw, "matchedAt": matched, "matchedCursor": matched.UTC().Format(time.RFC3339Nano), "viewedAt": viewed})
		}
		return map[string]any{"matches": matches}, rows.Err()
	case "viewed":
		if len(in.ListingIDs) > 100 {
			return nil, alertError(connect.CodeInvalidArgument, "Too many listings.")
		}
		id, err := uuid.Parse(in.ID)
		if err != nil {
			return nil, alertError(connect.CodeInvalidArgument, "Invalid alert ID.")
		}
		_, err = s.pool.Exec(ctx, `UPDATE price_alert_listings l SET viewed_at=COALESCE(l.viewed_at,now()) FROM price_alerts a WHERE a.id=l.alert_id AND a.user_id=$1 AND a.id=$2 AND l.matched AND l.listing_id=ANY($3)`, userID, id, in.ListingIDs)
		return nil, err
	default:
		return nil, alertError(connect.CodeNotFound, "Unknown action.")
	}
}

type alertQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func (s *alertsServer) eligibleDevice(ctx context.Context, q alertQuerier, session uuid.UUID) (uuid.UUID, error) {
	var device uuid.UUID
	err := q.QueryRow(ctx, `SELECT d.id FROM user_devices d JOIN user_sessions s ON s.device_id=d.id WHERE s.id=$1 AND s.revoked_at IS NULL AND s.refresh_token_expires_at>now() AND d.facebook_connected AND d.notification_permission_status='ENABLED' AND d.push_token IS NOT NULL`, session).Scan(&device)
	if errors.Is(err, pgx.ErrNoRows) {
		return device, alertError(connect.CodeFailedPrecondition, "Sign in, connect Facebook, and enable notifications on this device first.")
	}
	return device, err
}
func alertNotFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return alertError(connect.CodeNotFound, "Alert not found.")
	}
	return err
}

var alertCity = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,100}$`)
var alertListingID = regexp.MustCompile(`^[0-9]{1,40}$`)

func validateAlert(in alertRequest) error {
	l := in.Location
	if len([]rune(strings.TrimSpace(in.Query))) < 2 || len([]rune(in.Query)) > 300 || !alertCity.MatchString(l.CitySlug) || len(l.Name) > 200 || l.RadiusKM < 1 || l.RadiusKM > 500 || math.IsNaN(l.Latitude) || math.IsNaN(l.Longitude) || math.Abs(l.Latitude) > 90 || math.Abs(l.Longitude) > 180 {
		return alertError(connect.CodeInvalidArgument, "Enter a search of 2–300 characters and choose a valid location.")
	}
	return nil
}
func (s *alertsServer) list(ctx context.Context, user uuid.UUID) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT a.id,a.query,a.location,a.created_at,a.alert_hour,a.next_check_at,a.last_checked_at,a.paused,(SELECT count(*) FROM price_alert_listings l WHERE l.alert_id=a.id AND l.matched),(SELECT count(*) FROM price_alert_listings l WHERE l.alert_id=a.id AND l.matched AND l.viewed_at IS NULL) FROM price_alerts a WHERE a.user_id=$1 ORDER BY a.created_at`, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	alerts := []priceAlert{}
	for rows.Next() {
		var a priceAlert
		var location []byte
		if err = rows.Scan(&a.ID, &a.Query, &location, &a.CreatedAt, &a.AlertHour, &a.NextCheckAt, &a.LastCheckedAt, &a.Paused, &a.MatchCount, &a.UnreadCount); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(location, &a.Location); err != nil {
			return nil, err
		}
		alerts = append(alerts, a)
	}
	return map[string]any{"alerts": alerts}, rows.Err()
}

func (s *alertsServer) submitPage(ctx context.Context, user, session uuid.UUID, in alertRequest) error {
	id, err := uuid.Parse(in.CheckID)
	if err != nil {
		return alertError(connect.CodeInvalidArgument, "Invalid check ID.")
	}
	if len(in.Listings) > 100 || in.PageNumber < 0 || !alertListingID.MatchString(in.Actor) || (in.Cursor != nil && len(*in.Cursor) > 10000) || (!in.Complete && (in.Cursor == nil || *in.Cursor == "")) {
		return alertError(connect.CodeInvalidArgument, "Invalid search page.")
	}
	for _, l := range in.Listings {
		if !alertListingID.MatchString(l.ID) || strings.TrimSpace(l.Title) == "" || len(l.Title) > 2000 || len(l.Description) > 10000 || len(l.ThumbnailURL) > 4000 || len(l.PriceText) > 100 || len(l.LocationText) > 300 || len(l.Condition) > 200 {
			return alertError(connect.CodeInvalidArgument, "Invalid listing.")
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	device, err := s.eligibleDevice(ctx, tx, session)
	if err != nil {
		return err
	}
	var alertID uuid.UUID
	var page int
	var actor, cursor *string
	var done bool
	err = tx.QueryRow(ctx, `SELECT a.id,c.page_number,c.facebook_actor,c.cursor,c.scan_complete FROM price_alert_checks c JOIN price_alerts a ON a.id=c.alert_id WHERE c.id=$1 AND a.user_id=$2 AND a.device_id=$3 AND NOT a.paused AND c.completed_at IS NULL FOR UPDATE OF a,c`, id, user, device).Scan(&alertID, &page, &actor, &cursor, &done)
	if err != nil {
		return alertNotFound(err)
	}
	if in.PageNumber < page {
		return nil
	} // Retried upload after its response was lost.
	if in.PageNumber != page || done {
		return alertError(connect.CodeAborted, "Stale page.")
	}
	if actor != nil && *actor != in.Actor {
		return alertError(connect.CodeFailedPrecondition, "Facebook account changed. Pause and resume this alert to restart its search.")
	}
	if !in.Complete && cursor != nil && in.Cursor != nil && *cursor == *in.Cursor {
		return alertError(connect.CodeInvalidArgument, "Search cursor did not advance.")
	}
	for _, l := range in.Listings {
		raw, _ := json.Marshal(l)
		if _, err = tx.Exec(ctx, `INSERT INTO price_alert_listings(alert_id,listing_id,check_id,listing) VALUES($1,$2,$3,$4) ON CONFLICT(alert_id,listing_id) DO NOTHING`, alertID, l.ID, id, raw); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE price_alert_checks SET cursor=$2,facebook_actor=$3,page_number=page_number+1,scan_complete=$4 WHERE id=$1`, id, in.Cursor, in.Actor, in.Complete)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}
