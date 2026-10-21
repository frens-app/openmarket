package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/config"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/llm"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type fakeAlertPush struct {
	sent []map[string]any
	fail bool
}

func (p *fakeAlertPush) Send(_ context.Context, _, _ string, _ bool, payload map[string]any) error {
	if p.fail {
		return errors.New("offline")
	}
	p.sent = append(p.sent, payload)
	return nil
}

type fakeAlertEvaluator struct {
	inputs []llm.EvaluationInput
	fail   bool
}

func (e *fakeAlertEvaluator) Evaluate(_ context.Context, _ llm.Subject, in llm.EvaluationInput) ([]llm.Decision, error) {
	e.inputs = append(e.inputs, in)
	if e.fail {
		return nil, errors.New("unavailable")
	}
	out := []llm.Decision{}
	for _, c := range in.Candidates {
		out = append(out, llm.Decision{ID: c.ID, UseInComparison: c.Item.Title != "wrong product", Probability: 0.95})
	}
	return out, nil
}

func TestAlertValidation(t *testing.T) {
	valid := alertRequest{Query: "Nintendo Switch", Location: alertLocation{CitySlug: "sanfrancisco", RadiusKM: 16, Latitude: 37, Longitude: -122}}
	if err := validateAlert(valid); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*alertRequest){func(r *alertRequest) { r.Query = " " }, func(r *alertRequest) { r.Query = strings.Repeat("a", 301) }, func(r *alertRequest) { r.Location.CitySlug = "../../evil" }, func(r *alertRequest) { r.Location.Latitude = 91 }, func(r *alertRequest) { r.Location.RadiusKM = 0 }} {
		r := valid
		change(&r)
		if validateAlert(r) == nil {
			t.Fatal("accepted invalid alert")
		}
	}
	hour, minute, badHour, badMinute := 20, 15, 24, 60
	for _, schedule := range []alertRequest{
		{AlertHour: &hour}, {AlertMinute: &minute}, {TimeZone: "America/Toronto"},
		{AlertHour: &badHour, AlertMinute: &minute, TimeZone: "UTC"},
		{AlertHour: &hour, AlertMinute: &badMinute, TimeZone: "UTC"},
		{AlertHour: &hour, AlertMinute: &minute, TimeZone: "Not/AZone"},
		{AlertHour: &hour, AlertMinute: &minute, TimeZone: "Local"},
	} {
		schedule.Query, schedule.Location = valid.Query, valid.Location
		if validateAlert(schedule) == nil {
			t.Fatal("accepted invalid daily schedule")
		}
	}
	for _, tc := range []struct{ timestamp, want string }{{"2026-10-01T19:29:59Z", "2026-10-01T19:00:00Z"}, {"2026-10-01T19:30:00Z", "2026-10-01T20:00:00Z"}, {"2026-10-01T23:45:00Z", "2026-10-02T00:00:00Z"}} {
		value, _ := time.Parse(time.RFC3339, tc.timestamp)
		if got := value.Round(time.Hour).Format(time.RFC3339); got != tc.want {
			t.Fatalf("round %s = %s", tc.timestamp, got)
		}
	}
}
func TestAlertPriceValidation(t *testing.T) {
	for _, tc := range []struct {
		name     string
		min, max *int
		valid    bool
	}{
		{"any", nil, nil, true},
		{"minimum", intPtr(10), nil, true},
		{"maximum", nil, intPtr(100), true},
		{"free", nil, intPtr(0), true},
		{"equal", intPtr(50), intPtr(50), true},
		{"range", intPtr(10), intPtr(100), true},
		{"limit", nil, intPtr(2147483647), true},
		{"negative minimum", intPtr(-1), nil, false},
		{"negative maximum", nil, intPtr(-1), false},
		{"too large", nil, intPtr(2147483648), false},
		{"reversed", intPtr(100), intPtr(10), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := alertRequest{Query: "Switch", Location: alertLocation{CitySlug: "toronto", RadiusKM: 16}, MinPrice: tc.min, MaxPrice: tc.max}
			if err := validateAlert(r); (err == nil) != tc.valid {
				t.Fatalf("validation = %v, valid = %v", err, tc.valid)
			}
		})
	}
}

func intPtr(value int) *int { return &value }

func TestAlertEvaluationPriceRequirements(t *testing.T) {
	for _, tc := range []struct {
		min, max *int
		want     string
	}{
		{nil, nil, ""},
		{intPtr(10), nil, "Minimum price: 10 (inclusive)."},
		{nil, intPtr(0), "Maximum price: 0 (inclusive)."},
		{intPtr(10), intPtr(100), "Minimum price: 10 (inclusive). Maximum price: 100 (inclusive)."},
	} {
		target := alertEvaluationTarget("Switch OLED", tc.min, tc.max)
		if target.Title != "Switch OLED" || !strings.HasPrefix(target.Description, tc.want) || (tc.want == "" && target.Description != "") {
			t.Fatalf("unexpected target: %+v", target)
		}
	}
}

func TestAlertsHTTPRequiresAuthentication(t *testing.T) {
	s := &alertsServer{logger: zap.NewNop()}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/v1/listing-alerts/list", strings.NewReader(`{}`)))
	if w.Code != 401 {
		t.Fatalf("got %d", w.Code)
	}
}

// Use a disposable Postgres 18 database; never a development or production database.
func TestAlertsIntegration(t *testing.T) {
	dsn := os.Getenv("ALERTS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set ALERTS_TEST_DATABASE_URL to a disposable Postgres 18 database")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sqlDB := stdlib.OpenDBFromPool(pool)
	defer sqlDB.Close()
	goose.SetLogger(goose.NopLogger())
	if err = goose.SetDialect("postgres"); err != nil {
		t.Fatal(err)
	}
	if err = goose.Up(sqlDB, "../../deployments/migrations"); err != nil {
		t.Fatal(err)
	}
	fixture := func(t *testing.T) (*alertsServer, context.Context, uuid.UUID, uuid.UUID, *fakeAlertPush, *fakeAlertEvaluator) {
		t.Helper()
		var user, device, session uuid.UUID
		if err := pool.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id`).Scan(&user); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, user) })
		if _, err := pool.Exec(ctx, `INSERT INTO user_auth_methods(user_id,auth_service,subject) VALUES($1,'GOOGLE',$2)`, user, uuid.NewString()); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `INSERT INTO user_devices(user_id,install_id,platform,facebook_connected,push_token,notification_permission_status) VALUES($1,$2,'IOS',true,$3,'ENABLED') RETURNING id`, user, uuid.NewString(), uuid.NewString()).Scan(&device); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `INSERT INTO user_sessions(user_id,device_id,device_platform,refresh_token_hash,refresh_token_expires_at) VALUES($1,$2,'IOS',$3,now()+interval '1 day') RETURNING id`, user, device, uuid.NewString()).Scan(&session); err != nil {
			t.Fatal(err)
		}
		p := &fakeAlertPush{}
		e := &fakeAlertEvaluator{}
		options, err := config.ParseAlertSearchOptions("")
		if err != nil {
			t.Fatal(err)
		}
		s := &alertsServer{baseAlertLimit: 3, searchOptions: options, pool: pool, queries: db.New(pool), push: p, evaluator: e, logger: zap.NewNop()}
		return s, auth.WithSessionID(auth.WithUserID(ctx, user), session), user, device, p, e
	}
	create := func(t *testing.T, s *alertsServer, ctx context.Context) string {
		t.Helper()
		out, err := s.handle(ctx, "create", alertRequest{Query: "Switch OLED", Location: alertLocation{CitySlug: "sanfrancisco", Name: "San Francisco", RadiusKM: 16, Latitude: 37, Longitude: -122}})
		if err != nil {
			t.Fatal(err)
		}
		return out.(map[string]string)["id"]
	}
	exec := func(t *testing.T, sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	dispatch := func(t *testing.T, s *alertsServer) {
		t.Helper()
		exec(t, `UPDATE listing_alert_worker_clock SET next_dispatch_at=now()-interval '1 minute'`)
		if err := s.dispatch(ctx, 30*time.Second); err != nil {
			t.Fatal(err)
		}
	}
	getWork := func(t *testing.T, s *alertsServer, ctx context.Context) []alertWork {
		t.Helper()
		v, err := s.handle(ctx, "work", alertRequest{})
		if err != nil {
			t.Fatal(err)
		}
		return v.(map[string]any)["work"].([]alertWork)
	}

	for _, tc := range []struct {
		name     string
		min, max *int
	}{
		{"any", nil, nil}, {"minimum", intPtr(10), nil},
		{"maximum", nil, intPtr(100)}, {"range", intPtr(10), intPtr(100)},
		{"free", nil, intPtr(0)},
	} {
		t.Run("saved price limits "+tc.name, func(t *testing.T) {
			s, c, user, _, _, evaluator := fixture(t)
			request := alertRequest{Query: "Switch OLED", Location: alertLocation{CitySlug: "toronto", RadiusKM: 16}, MinPrice: tc.min, MaxPrice: tc.max}
			created, err := s.handle(c, "create", request)
			if err != nil {
				t.Fatal(err)
			}
			id := created.(map[string]string)["id"]
			listed, err := s.list(c, user)
			if err != nil {
				t.Fatal(err)
			}
			alert := listed.(map[string]any)["alerts"].([]listingAlert)[0]
			assertBounds := func(min, max *int) {
				t.Helper()
				if (min == nil) != (tc.min == nil) || (max == nil) != (tc.max == nil) ||
					(min != nil && *min != *tc.min) || (max != nil && *max != *tc.max) {
					t.Fatalf("price limits did not round trip: %v/%v", min, max)
				}
			}
			assertBounds(alert.MinPrice, alert.MaxPrice)
			encoded, _ := json.Marshal(alert)
			if (tc.min == nil && strings.Contains(string(encoded), `"minPrice"`)) || (tc.max == nil && strings.Contains(string(encoded), `"maxPrice"`)) {
				t.Fatal("unset bounds must be omitted", string(encoded))
			}
			exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 minute' WHERE id=$1`, id)
			dispatch(t, s)
			work := getWork(t, s, c)[0]
			assertBounds(work.SearchOptions.MinPrice, work.SearchOptions.MaxPrice)
			traced, err := s.handle(c, "work", alertRequest{Trigger: "foreground"})
			if err != nil {
				t.Fatal(err)
			}
			fetch := traced.(map[string]any)["work"].([]alertWork)[0]
			var snapshot []byte
			if err = pool.QueryRow(ctx, `SELECT search_request FROM listing_alert_background_fetch_attempts WHERE id=$1`, fetch.FetchAttemptID).Scan(&snapshot); err != nil {
				t.Fatal(err)
			}
			var saved alertWork
			if err = json.Unmarshal(snapshot, &saved); err != nil {
				t.Fatal(err)
			}
			assertBounds(saved.SearchOptions.MinPrice, saved.SearchOptions.MaxPrice)
			_, err = s.handle(c, "page", alertRequest{CheckID: work.ID, Actor: "123", Complete: true, Listings: []alertListing{{ID: "123", Title: "Switch OLED", PriceText: "$50"}}})
			if err != nil {
				t.Fatal(err)
			}
			if err = s.evaluateBatch(ctx); err != nil {
				t.Fatal(err)
			}
			if len(evaluator.inputs) != 1 || evaluator.inputs[0].Target != alertEvaluationTarget(request.Query, tc.min, tc.max) {
				t.Fatal("saved limits did not reach evaluator", evaluator.inputs)
			}
		})
	}

	t.Run("flat inbox pagination filters and atomic save attribution", func(t *testing.T) {
		s, c, user, _, _, _ := fixture(t)
		_, otherContext, otherUser, _, _, _ := fixture(t)
		seed := func(alertID string, count int) string {
			t.Helper()
			var checkID, notificationID string
			if err := pool.QueryRow(ctx, `INSERT INTO listing_alert_check_runs(alert_id,scan_complete,completed_at) VALUES($1,true,now()) RETURNING id`, alertID).Scan(&checkID); err != nil {
				t.Fatal(err)
			}
			ids := []string{}
			for i := 0; i < count; i++ {
				id := fmt.Sprint(1000 + i)
				ids = append(ids, id)
				raw, _ := json.Marshal(alertListing{ID: id, Title: "Switch OLED", PriceText: "$50"})
				exec(t, `INSERT INTO listing_alert_listings(alert_id,listing_id,check_id,listing,matched,matched_at) VALUES($1,$2,$3,$4,true,now())`, alertID, id, checkID, raw)
			}
			if err := pool.QueryRow(ctx, `INSERT INTO listing_alert_notification_outbox(alert_id,check_id,listing_ids,created_at) VALUES($1,$2,$3,'2026-10-17T12:34:56.123456Z') RETURNING id`, alertID, checkID, ids).Scan(&notificationID); err != nil {
				t.Fatal(err)
			}
			return notificationID
		}
		firstAlert, secondAlert := create(t, s, c), create(t, s, c)
		firstNotification, secondNotification := seed(firstAlert, 55), seed(secondAlert, 2)
		inbox := func(owner uuid.UUID, request alertRequest) []alertInboxItem {
			t.Helper()
			out, err := s.inbox(ctx, owner, request)
			if err != nil {
				t.Fatal(err)
			}
			return out.(map[string]any)["items"].([]alertInboxItem)
		}
		listingID := func(item alertInboxItem) string {
			var listing alertListing
			if err := json.Unmarshal(item.Listing, &listing); err != nil {
				t.Fatal(err)
			}
			return listing.ID
		}
		page := inbox(user, alertRequest{})
		if len(page) != 50 {
			t.Fatalf("first inbox page = %d", len(page))
		}
		last := page[len(page)-1]
		before, err := time.Parse(time.RFC3339Nano, last.CreatedCursor)
		if err != nil {
			t.Fatal(err)
		}
		next := inbox(user, alertRequest{Before: &before, NotificationID: last.NotificationID, BeforeID: listingID(last)})
		if len(next) != 7 {
			t.Fatalf("next inbox page = %d", len(next))
		}
		seen := map[string]bool{}
		for _, item := range append(page, next...) {
			key := item.NotificationID + ":" + listingID(item)
			if seen[key] {
				t.Fatal("duplicate inbox row", key)
			}
			seen[key] = true
			if item.CreatedCursor != "2026-10-17T12:34:56.123456Z" {
				t.Fatal("lost cursor precision")
			}
		}
		if len(inbox(otherUser, alertRequest{})) != 0 {
			t.Fatal("inbox leaked to another account")
		}
		for _, request := range []alertRequest{{Filter: "invalid"}, {Before: &before, NotificationID: "bad", BeforeID: "1000"}} {
			if _, err := s.inbox(ctx, user, request); connect.CodeOf(err) != connect.CodeInvalidArgument {
				t.Fatal("accepted invalid inbox request", err)
			}
		}
		saves := &savedListingServer{pool: pool, queries: db.New(pool)}
		makeSave := func(alert, notification string) *v1.SavedListingChange {
			now := timestamppb.Now()
			return &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: "1000", Saved: proto.Bool(true), SavedAt: now,
				Snapshot:    &v1.SavedListingSnapshot{FacebookListingId: "1000", Title: proto.String("Switch OLED"), CardObservedAt: now},
				AlertSource: &v1.ListingAlertSaveSource{AlertId: alert, NotificationId: &notification, Source: "alerts_tab"}}
		}
		change := makeSave(firstAlert, firstNotification)
		for i := 0; i < 2; i++ {
			response, err := saves.ApplySavedListingChanges(c, connect.NewRequest(&v1.ApplySavedListingChangesRequest{Changes: []*v1.SavedListingChange{change}}))
			if err != nil {
				t.Fatal(err)
			}
			if len(response.Msg.Results) != 1 || response.Msg.Results[0].Error != "" {
				t.Fatal("save endpoint rejected attribution", response.Msg)
			}
		}
		var saveCount, eventCount int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM saved_listings s JOIN listings l ON l.id=s.listing_id WHERE s.user_id=$1 AND l.facebook_listing_id='1000'`, user).Scan(&saveCount); err != nil || saveCount != 1 {
			t.Fatal("save endpoint did not save", saveCount, err)
		}
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_interactions WHERE alert_id=$1 AND notification_id=$2 AND listing_id='1000' AND kind='listing_saved'`, firstAlert, firstNotification).Scan(&eventCount); err != nil || eventCount != 1 {
			t.Fatal("save attribution not idempotent", eventCount, err)
		}
		var savedAt time.Time
		if err := pool.QueryRow(ctx, `SELECT saved_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='1000'`, firstAlert).Scan(&savedAt); err != nil {
			t.Fatal(err)
		}
		var otherSaved *time.Time
		if err := pool.QueryRow(ctx, `SELECT saved_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='1000'`, secondAlert).Scan(&otherSaved); err != nil || otherSaved != nil {
			t.Fatal("attributed to wrong alert", err)
		}
		if len(inbox(user, alertRequest{Filter: "saved"})) != 2 {
			t.Fatal("saved filter must reflect current bookmark across both matches")
		}
		groups, err := s.notificationFeed(ctx, user, alertRequest{})
		if err != nil {
			t.Fatal(err)
		}
		for _, group := range groups.(map[string]any)["groups"].([]alertNotificationGroup) {
			if group.SeenAt != nil {
				t.Fatal("saving marked notification read")
			}
		}
		if err := s.recordInteraction(c, user, alertRequest{ID: firstAlert, NotificationID: firstNotification, ListingID: "1000", InteractionID: uuid.NewString(), Event: "listing_saved", Source: "alerts_tab"}); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatal("save engagement was accepted outside the saved-listing endpoint", err)
		}
		opened := alertRequest{ID: firstAlert, NotificationID: firstNotification, ListingID: "1000", InteractionID: uuid.NewString(), Event: "listing_opened", Source: "alerts_tab"}
		if err := s.recordInteraction(c, user, opened); err != nil {
			t.Fatal(err)
		}
		unread := inbox(user, alertRequest{Filter: "unread"})
		for _, item := range unread {
			if item.AlertID == firstAlert && listingID(item) == "1000" {
				t.Fatal("opened listing stayed unread")
			}
		}
		// A foreign account or mismatched batch cannot attribute a save to this match.
		if err := saves.apply(otherContext, otherUser, makeSave(secondAlert, secondNotification)); err != nil {
			t.Fatal(err)
		}
		if err := saves.apply(ctx, user, makeSave(secondAlert, firstNotification)); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `SELECT saved_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='1000'`, secondAlert).Scan(&otherSaved); err != nil || otherSaved != nil {
			t.Fatal("invalid attribution accepted", err)
		}
		remove := &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: "1000", Saved: proto.Bool(false)}
		if err := saves.apply(ctx, user, remove); err != nil {
			t.Fatal(err)
		}
		if err := saves.apply(ctx, user, change); err != nil {
			t.Fatal(err)
		} // Lost save acknowledgment after an unsave.
		if len(inbox(user, alertRequest{Filter: "saved"})) != 0 {
			t.Fatal("old retry recreated removed save")
		}
		var retained time.Time
		if err := pool.QueryRow(ctx, `SELECT saved_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='1000'`, firstAlert).Scan(&retained); err != nil || !retained.Equal(savedAt) {
			t.Fatal("unsave erased save history", err)
		}
		stale := makeSave(secondAlert, secondNotification)
		exec(t, `DELETE FROM user_listing_alerts WHERE id=$1`, secondAlert)
		if err := saves.apply(ctx, user, stale); err != nil {
			t.Fatal("deleted alert prevented offline save", err)
		}
	})

	for _, provider := range []string{"GOOGLE", "APPLE"} {
		t.Run("alerts require linked "+provider, func(t *testing.T) {
			s, c, user, _, push, evaluator := fixture(t)
			exec(t, `DELETE FROM user_auth_methods WHERE user_id=$1`, user)
			exec(t, `INSERT INTO user_auth_methods(user_id,auth_service,subject) VALUES($1,'PHONE',$2)`, user, uuid.NewString())
			request := alertRequest{Query: "Switch OLED", Location: alertLocation{CitySlug: "toronto", RadiusKM: 16, Latitude: 43, Longitude: -79}}
			if _, err := s.handle(c, "create", request); connect.CodeOf(err) != connect.CodeFailedPrecondition || !strings.Contains(err.Error(), "Google or Apple") {
				t.Fatalf("phone-only creation not blocked clearly: %v", err)
			}
			link := func() {
				exec(t, `INSERT INTO user_auth_methods(user_id,auth_service,subject) VALUES($1,$2,$3)`, user, provider, uuid.NewString())
			}
			unlink := func() {
				exec(t, `DELETE FROM user_auth_methods WHERE user_id=$1 AND auth_service IN ('GOOGLE','APPLE')`, user)
			}
			link()
			id := create(t, s, c)
			exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
			unlink()
			dispatch(t, s)
			if len(push.sent) != 0 {
				t.Fatal("sent background push to phone-only account")
			}
			link()
			dispatch(t, s)
			work := getWork(t, s, c)[0]
			upload := alertRequest{CheckID: work.ID, Actor: "123", Complete: true, Listings: []alertListing{{ID: "123", Title: "Switch OLED"}}}
			unlink()
			for _, action := range []string{"work", "page", "state"} {
				in := upload
				in.ID = id
				if _, err := s.handle(c, action, in); connect.CodeOf(err) != connect.CodeFailedPrecondition {
					t.Fatalf("phone-only %s allowed: %v", action, err)
				}
			}
			link()
			if _, err := s.handle(c, "page", upload); err != nil {
				t.Fatal(err)
			}
			unlink()
			if err := s.evaluateBatch(ctx); err != nil || len(evaluator.inputs) != 0 {
				t.Fatal("evaluated phone-only alert", err)
			}
			link()
			if err := s.evaluateBatch(ctx); err != nil || len(evaluator.inputs) != 1 {
				t.Fatal("linked alert not evaluated", err)
			}
			unlink()
			if err := s.notifyMatches(ctx); err != nil || len(push.sent) != 1 {
				t.Fatal("sent match notification to phone-only account", err)
			}
			link()
			if err := s.notifyMatches(ctx); err != nil || len(push.sent) != 2 {
				t.Fatal("linked alert notification not sent", err)
			}
			unlink()
			if _, err := s.handle(c, "state", alertRequest{ID: id, Paused: true}); err != nil {
				t.Fatal("phone-only account cannot pause an alert", err)
			}
			if _, err := s.handle(c, "delete", alertRequest{ID: id}); err != nil {
				t.Fatal("phone-only account cannot delete an alert", err)
			}
		})
	}

	t.Run("interaction attribution ownership and idempotence", func(t *testing.T) {
		s, c, _, _, push, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		work := getWork(t, s, c)[0]
		if _, err := s.handle(c, "page", alertRequest{CheckID: work.ID, Actor: "123", Complete: true, Listings: []alertListing{{ID: "123", Title: "Nintendo Switch"}, {ID: "456", Title: "wrong product"}}}); err != nil {
			t.Fatal(err)
		}
		if err := s.evaluateBatch(ctx); err != nil {
			t.Fatal(err)
		}
		if err := s.notifyMatches(ctx); err != nil {
			t.Fatal(err)
		}
		notification := push.sent[len(push.sent)-1]["notification_id"].(string)
		getGroup := func() alertNotificationGroup {
			t.Helper()
			result, err := s.handle(c, "notification-feed", alertRequest{})
			if err != nil {
				t.Fatal(err)
			}
			groups := result.(map[string]any)["groups"].([]alertNotificationGroup)
			if len(groups) != 1 {
				t.Fatalf("expected one group, got %d", len(groups))
			}
			return groups[0]
		}
		if getGroup().SeenAt != nil {
			t.Fatal("unopened group was marked seen")
		}

		request := alertRequest{ID: id, InteractionID: uuid.NewString(), NotificationID: notification, Source: "notification", Event: "alert_opened"}
		_, other, _, _, _, _ := fixture(t)
		if _, err := s.handle(other, "interaction", request); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross account: %v", err)
		}
		for range 2 {
			if _, err := s.handle(c, "interaction", request); err != nil {
				t.Fatal(err)
			}
		}
		var count int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_interactions WHERE alert_id=$1`, id).Scan(&count); err != nil || count != 1 {
			t.Fatalf("duplicate event: %d %v", count, err)
		}
		seenGroup := getGroup()
		if seenGroup.SeenAt == nil || seenGroup.UnreadCount != 1 {
			t.Fatal("group open must mark group seen without marking listings viewed")
		}
		var viewedCount int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_listings WHERE alert_id=$1 AND viewed_at IS NOT NULL`, id).Scan(&viewedCount); err != nil || viewedCount != 0 {
			t.Fatalf("group open changed listing views: %d %v", viewedCount, err)
		}
		request.InteractionID = uuid.NewString()
		request.Event = "listing_opened"
		request.ListingID = "123"
		if _, err := s.handle(c, "interaction", request); err != nil {
			t.Fatal(err)
		}
		var first time.Time
		if err := pool.QueryRow(ctx, `SELECT viewed_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='123'`, id).Scan(&first); err != nil {
			t.Fatal(err)
		}
		request.InteractionID = uuid.NewString()
		request.Source = "alerts_tab"
		request.NotificationID = ""
		if _, err := s.handle(c, "interaction", request); err != nil {
			t.Fatal(err)
		}
		var last time.Time
		if err := pool.QueryRow(ctx, `SELECT viewed_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='123'`, id).Scan(&last); err != nil || !last.Equal(first) {
			t.Fatalf("first view changed: %v", err)
		}
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_interactions WHERE alert_id=$1`, id).Scan(&count); err != nil || count != 3 {
			t.Fatalf("missing clicks: %d %v", count, err)
		}
		afterClick := getGroup()
		if afterClick.SeenAt == nil || !afterClick.SeenAt.Equal(*seenGroup.SeenAt) || afterClick.UnreadCount != 0 {
			t.Fatal("listing click must preserve first group-seen time and mark only its listing viewed")
		}
		request.ListingID = "456"
		request.InteractionID = uuid.NewString()
		if _, err := s.handle(c, "interaction", request); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("rejected listing click: %v", err)
		}
		request.ListingID = "123"
		request.Source = "notification"
		request.NotificationID = uuid.NewString()
		if _, err := s.handle(c, "interaction", request); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("unrelated notification: %v", err)
		}
		request.Source = "bogus"
		if _, err := s.handle(c, "interaction", request); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("invalid source: %v", err)
		}
		for _, source := range []string{"search", "search_history"} {
			request.Source = source
			request.NotificationID = ""
			request.InteractionID = uuid.NewString()
			if _, err := s.handle(c, "interaction", request); err != nil {
				t.Fatalf("%s: %v", source, err)
			}
			var storedSource string
			if err := pool.QueryRow(ctx, `SELECT source FROM listing_alert_interactions WHERE id=$1`, request.InteractionID).Scan(&storedSource); err != nil || storedSource != source {
				t.Fatalf("search attribution: %q %v", storedSource, err)
			}
			request.NotificationID = notification
			if _, err := s.handle(c, "interaction", request); connect.CodeOf(err) != connect.CodeInvalidArgument {
				t.Fatalf("search cannot claim a notification: %v", err)
			}
		}
	})

	t.Run("concurrent limit and exact schedule", func(t *testing.T) {
		s, c, user, _, _, _ := fixture(t)
		s.baseAlertLimit = 1
		var wg sync.WaitGroup
		var mu sync.Mutex
		success, limited := 0, 0
		for range 8 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, err := s.handle(c, "create", alertRequest{Query: "Switch OLED", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}})
				mu.Lock()
				defer mu.Unlock()
				if err == nil {
					success++
				} else if connect.CodeOf(err) == connect.CodeResourceExhausted {
					limited++
				} else {
					t.Error(err)
				}
			}()
		}
		wg.Wait()
		if success != 1 || limited != 7 {
			t.Fatalf("success=%d limited=%d", success, limited)
		}
		var created, next time.Time
		var hour int
		if err := pool.QueryRow(ctx, `SELECT created_at,next_check_at,alert_hour FROM user_listing_alerts WHERE user_id=$1 LIMIT 1`, user).Scan(&created, &next, &hour); err != nil {
			t.Fatal(err)
		}
		if !created.UTC().Round(time.Hour).Equal(next) || hour != next.UTC().Hour() {
			t.Fatal("schedule is not rounded creation time")
		}
		exec(t, `UPDATE user_listing_alerts SET paused=true WHERE user_id=$1`, user)
		_, err := s.handle(c, "create", alertRequest{Query: "Fourth alert", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}})
		if err != nil {
			t.Fatalf("paused alert did not free its slot: %v", err)
		}
	})
	t.Run("allowance is per account and counts only active alerts", func(t *testing.T) {
		s, c, user, _, _, _ := fixture(t)
		s.baseAlertLimit = 1
		checkAllowance := func(active, limit int) {
			t.Helper()
			out, err := s.handle(c, "list", alertRequest{})
			if err != nil {
				t.Fatal(err)
			}
			if got := out.(map[string]any)["allowance"].(alertAllowance); got != (alertAllowance{Active: active, Limit: limit}) {
				t.Fatalf("allowance = %+v, want active=%d limit=%d", got, active, limit)
			}
		}
		state := func(id string, paused bool) {
			t.Helper()
			if _, err := s.handle(c, "state", alertRequest{ID: id, Paused: paused}); err != nil {
				t.Fatal(err)
			}
		}
		checkAllowance(0, 1)
		first := create(t, s, c)
		checkAllowance(1, 1)
		state(first, true)
		checkAllowance(0, 1)
		second := create(t, s, c)
		if _, err := s.handle(c, "state", alertRequest{ID: first}); connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("resume exceeded allowance: %v", err)
		}
		// A future referral grant changes this server-owned value, not alert rows.
		exec(t, `UPDATE users SET listing_alert_bonus_slots=1 WHERE id=$1`, user)
		state(first, false)
		checkAllowance(2, 2)
		other, otherCtx, _, _, _, _ := fixture(t)
		other.baseAlertLimit = 1
		out, err := other.handle(otherCtx, "list", alertRequest{})
		if err != nil {
			t.Fatal(err)
		}
		if out.(map[string]any)["allowance"].(alertAllowance).Limit != 1 {
			t.Fatal("bonus leaked to another account")
		}
		if _, err := pool.Exec(ctx, `UPDATE users SET listing_alert_bonus_slots=-1 WHERE id=$1`, user); err == nil {
			t.Fatal("negative bonus accepted")
		}
		// Lowering an allowance preserves existing alerts but prevents new activations.
		exec(t, `UPDATE users SET listing_alert_bonus_slots=0 WHERE id=$1`, user)
		checkAllowance(2, 1)
		state(first, false) // Retrying an already-active alert needs no extra slot.
		if _, err := s.handle(c, "create", alertRequest{Query: "Another alert", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}}); connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("over-limit account created another alert: %v", err)
		}
		state(first, true)
		if _, err := s.handle(c, "state", alertRequest{ID: first}); connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("resume at limit succeeded: %v", err)
		}
		if _, err := s.handle(c, "delete", alertRequest{ID: second}); err != nil {
			t.Fatal(err)
		}
		state(first, false)
		checkAllowance(1, 1)
	})
	t.Run("concurrent creation and resumption share the last slot", func(t *testing.T) {
		s, c, user, _, _, _ := fixture(t)
		ids := []string{create(t, s, c), create(t, s, c), create(t, s, c)}
		exec(t, `UPDATE user_listing_alerts SET paused=true WHERE user_id=$1`, user)
		s.baseAlertLimit = 1
		results := make(chan error, 6)
		for _, id := range ids {
			go func() { _, err := s.handle(c, "state", alertRequest{ID: id}); results <- err }()
			go func() {
				_, err := s.handle(c, "create", alertRequest{Query: "New search", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}})
				results <- err
			}()
		}
		success, limited := 0, 0
		for range 6 {
			if err := <-results; err == nil {
				success++
			} else if connect.CodeOf(err) == connect.CodeResourceExhausted {
				limited++
			} else {
				t.Error(err)
			}
		}
		if success != 1 || limited != 5 {
			t.Fatalf("success=%d limited=%d", success, limited)
		}
		var active int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM user_listing_alerts WHERE user_id=$1 AND NOT paused`, user).Scan(&active); err != nil {
			t.Fatal(err)
		}
		if active != 1 {
			t.Fatalf("active=%d", active)
		}
	})
	t.Run("chosen daily time and daylight saving schedule", func(t *testing.T) {
		for _, tc := range []struct {
			after        string
			hour, minute int
			zone, want   string
		}{
			{"2026-10-17T12:00:00Z", 20, 15, "America/Toronto", "2026-10-18T00:15:00Z"},
			{"2026-10-18T00:16:00Z", 20, 15, "America/Toronto", "2026-10-19T00:15:00Z"},
			{"2026-03-08T01:00:00Z", 20, 0, "America/Toronto", "2026-03-09T00:00:00Z"},
			{"2026-11-01T00:00:00Z", 20, 0, "America/Toronto", "2026-11-02T01:00:00Z"},
			{"2026-03-08T06:00:00Z", 2, 30, "America/Toronto", "2026-03-08T07:30:00Z"},
			{"2026-11-01T04:00:00Z", 1, 30, "America/Toronto", "2026-11-01T06:30:00Z"},
			{"2026-11-01T06:30:00Z", 1, 30, "America/Toronto", "2026-11-02T06:30:00Z"},
			{"2026-10-17T12:00:00Z", 20, 15, "Asia/Kathmandu", "2026-10-17T14:30:00Z"},
		} {
			after, _ := time.Parse(time.RFC3339, tc.after)
			var got time.Time
			if err := pool.QueryRow(ctx, `SELECT next_listing_alert_check_time($1,$2,$3,$4)`, after, tc.hour, tc.minute, tc.zone).Scan(&got); err != nil {
				t.Fatal(err)
			}
			if got.UTC().Format(time.RFC3339) != tc.want {
				t.Fatalf("%s %s %d:%d = %s, want %s", tc.after, tc.zone, tc.hour, tc.minute, got, tc.want)
			}
		}
		s, c, _, _, _, _ := fixture(t)
		hour, minute := 20, 15
		out, err := s.handle(c, "create", alertRequest{Query: "Anthurium", Location: alertLocation{CitySlug: "toronto", RadiusKM: 16}, AlertHour: &hour, AlertMinute: &minute, TimeZone: "America/Toronto"})
		if err != nil {
			t.Fatal(err)
		}
		id := out.(map[string]string)["id"]
		var created, next time.Time
		var storedHour, storedMinute int
		var zone string
		if err = pool.QueryRow(ctx, `SELECT created_at,next_check_at,alert_hour,alert_minute,time_zone FROM user_listing_alerts WHERE id=$1`, id).Scan(&created, &next, &storedHour, &storedMinute, &zone); err != nil {
			t.Fatal(err)
		}
		loc, _ := time.LoadLocation("America/Toronto")
		if storedHour != 20 || storedMinute != 15 || zone != "America/Toronto" || next.In(loc).Hour() != 20 || next.In(loc).Minute() != 15 || !next.After(created) {
			t.Fatal("chosen time not persisted/scheduled")
		}
		listed, err := s.handle(c, "list", alertRequest{})
		if err != nil {
			t.Fatal(err)
		}
		a := listed.(map[string]any)["alerts"].([]listingAlert)[0]
		if a.AlertHour != 20 || a.AlertMinute != 15 || a.TimeZone != zone {
			t.Fatal("list omitted chosen time")
		}
		exec(t, `UPDATE user_listing_alerts SET last_checked_at=now()-interval '23 hours',next_check_at=now()-interval '1 minute' WHERE id=$1`, id)
		dispatch(t, s)
		if len(getWork(t, s, c)) != 1 {
			t.Fatal("24-hour gate blocked a due local daily schedule")
		}
	})

	t.Run("replicas stagger oldest due work", func(t *testing.T) {
		s, c, _, _, p, _ := fixture(t)
		oldest := create(t, s, c)
		newest := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=ANY($1::uuid[])`, []string{oldest, newest})
		exec(t, `UPDATE user_listing_alerts SET created_at=created_at-interval '1 day' WHERE id=$1`, oldest)
		exec(t, `UPDATE listing_alert_worker_clock SET next_dispatch_at=now()-interval '1 minute'`)
		var wg sync.WaitGroup
		for range 6 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if err := s.tick(ctx, 30*time.Second); err != nil {
					t.Error(err)
				}
			}()
		}
		wg.Wait()
		work := getWork(t, s, c)
		if len(work) != 1 || work[0].AlertID != oldest || len(p.sent) != 1 {
			t.Fatalf("wrong staggered dispatch: %+v / %d pushes", work, len(p.sent))
		}
	})

	t.Run("work fetch uses current server search options", func(t *testing.T) {
		s, c, _, _, p, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 minute' WHERE id=$1`, id)
		dispatch(t, s)
		if _, err := s.handle(c, "work", alertRequest{Trigger: "foreground", Location: alertLocation{CitySlug: "toronto", RadiusKM: 16, Latitude: 100}}); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("invalid device location accepted: %v", err)
		}
		initial := getWork(t, s, c)
		if len(initial) != 1 || initial[0].Location.CitySlug != "sanfrancisco" {
			t.Fatal("missing device location did not fall back to saved alert")
		}
		if len(initial) != 1 || initial[0].SearchOptions.Sort != "best_match" {
			t.Fatalf("default work: %+v", initial)
		}
		options, err := config.ParseAlertSearchOptions(`{"sort":"price_ascend","minPrice":10,"maxPrice":100,"daysSinceListed":1}`)
		if err != nil {
			t.Fatal(err)
		}
		s.searchOptions = options
		updated := getWork(t, s, c)
		if len(updated) != 1 || updated[0].ID != initial[0].ID || updated[0].SearchOptions.Sort != "price_ascend" || updated[0].SearchOptions.MinPrice != nil || updated[0].SearchOptions.MaxPrice != nil || len(p.sent) != 1 {
			t.Fatalf("settings did not update for existing check: %+v", updated)
		}
		encoded, err := json.Marshal(updated[0])
		if err != nil || !strings.Contains(string(encoded), `"searchOptions":{"sort":"price_ascend"`) {
			t.Fatalf("work API omitted options: %s, %v", encoded, err)
		}
	})

	t.Run("background fetch traces receipts uploads and duplicate listings", func(t *testing.T) {
		s, c, _, device, p, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		attempt := p.sent[0]["fetch_attempt_id"].(string)
		check := p.sent[0]["check_id"].(string)
		_, other, _, _, _, _ := fixture(t)
		receipt := alertRequest{FetchAttemptID: attempt, Event: "acknowledged"}
		if _, err := s.handle(other, "fetch-event", receipt); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross-account receipt: %v", err)
		}
		if _, err := s.handle(other, "work", alertRequest{FetchAttemptID: attempt, Trigger: "background_push"}); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross-account work: %v", err)
		}
		exec(t, `UPDATE listing_alert_background_fetch_attempts SET send_started_at=clock_timestamp()-interval '10 seconds' WHERE id=$1`, attempt)
		if _, err := s.handle(c, "fetch-event", receipt); err != nil {
			t.Fatal(err)
		}
		var acknowledged time.Time
		if err := pool.QueryRow(ctx, `SELECT acknowledged_at FROM listing_alert_background_fetch_attempts WHERE id=$1`, attempt).Scan(&acknowledged); err != nil {
			t.Fatal(err)
		}
		if _, err := s.handle(c, "fetch-event", receipt); err != nil {
			t.Fatal(err)
		}
		deviceLocation := alertLocation{CitySlug: "toronto", Name: "Toronto", RadiusKM: 32, Latitude: 43.65, Longitude: -79.38}
		request := alertRequest{FetchAttemptID: attempt, Trigger: "background_push", Location: deviceLocation}
		v, err := s.handle(c, "work", request)
		if err != nil {
			t.Fatal(err)
		}
		work := v.(map[string]any)["work"].([]alertWork)
		if len(work) != 1 || work[0].ID != check || work[0].FetchAttemptID != attempt {
			t.Fatalf("wrong traced work: %+v", work)
		}
		if work[0].Location != deviceLocation {
			t.Fatal("work ignored latest device location")
		}
		s.searchOptions.Sort = "price_ascend"
		request.Location = alertLocation{CitySlug: "vancouver", Name: "Vancouver", RadiusKM: 16, Latitude: 49.28, Longitude: -123.12}
		v, err = s.handle(c, "work", request)
		if err != nil {
			t.Fatal(err)
		}
		if v.(map[string]any)["work"].([]alertWork)[0].Location != deviceLocation {
			t.Fatal("retry changed snapshotted location")
		}
		if v.(map[string]any)["work"].([]alertWork)[0].SearchOptions.Sort != "best_match" {
			t.Fatal("retry changed snapshotted search")
		}
		if _, err = s.handle(c, "fetch-event", alertRequest{FetchAttemptID: attempt, Event: "search_started"}); err != nil {
			t.Fatal(err)
		}
		upload := alertRequest{CheckID: check, FetchAttemptID: uuid.NewString(), Actor: "123", Complete: true, Listings: []alertListing{{ID: "201", Title: "Switch OLED"}, {ID: "202", Title: "wrong product"}}}
		if _, err = s.handle(c, "page", upload); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("unknown attempt upload: %v", err)
		}
		upload.FetchAttemptID = attempt
		if _, err = s.handle(c, "page", upload); err != nil {
			t.Fatal(err)
		}
		if err = s.evaluateBatch(ctx); err != nil {
			t.Fatal(err)
		}
		if _, err = s.handle(c, "page", upload); err != nil {
			t.Fatal("retry after check completion", err)
		}
		if _, err = s.handle(c, "fetch-event", alertRequest{FetchAttemptID: attempt, Event: "failed", FailureStage: "upload", FailureCode: "request_failed"}); err != nil {
			t.Fatal(err)
		}
		var sameReceipt, traced bool
		var seconds float64
		err = pool.QueryRow(ctx, `SELECT acknowledged_at=$2, apns_accepted_at IS NOT NULL AND work_requested_at IS NOT NULL AND search_started_at IS NOT NULL AND upload_received_at IS NOT NULL AND failure_at IS NULL AND jsonb_array_length(returned_listings)=2 AND search_request->>'query'='Switch OLED', extract(epoch FROM upload_received_at-send_started_at)::float8 FROM listing_alert_background_fetch_attempts WHERE id=$1`, attempt, acknowledged).Scan(&sameReceipt, &traced, &seconds)
		if err != nil || !sameReceipt || !traced || seconds < 10 {
			t.Fatalf("missing trace/timing: %v %v %v %f", err, sameReceipt, traced, seconds)
		}
		exec(t, `UPDATE user_listing_alerts SET last_checked_at=now()-interval '25 hours',next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		v, err = s.handle(c, "work", alertRequest{Trigger: "foreground", Location: request.Location})
		if err != nil {
			t.Fatal(err)
		}
		recovered := v.(map[string]any)["work"].([]alertWork)[0]
		if recovered.Location != request.Location {
			t.Fatal("new fetch retained creation location")
		}
		upload.CheckID, upload.FetchAttemptID = recovered.ID, recovered.FetchAttemptID
		if _, err = s.handle(c, "page", upload); err != nil {
			t.Fatal(err)
		}
		var duplicateTrace bool
		err = pool.QueryRow(ctx, `SELECT trigger='foreground' AND send_started_at IS NULL AND acknowledged_at IS NULL AND jsonb_array_length(returned_listings)=2 AND NOT EXISTS(SELECT 1 FROM listing_alert_listings WHERE check_id=$2) FROM listing_alert_background_fetch_attempts WHERE id=$1`, upload.FetchAttemptID, upload.CheckID).Scan(&duplicateTrace)
		if err != nil || !duplicateTrace {
			t.Fatalf("foreground/duplicate trace missing: %v", err)
		}
		exec(t, `UPDATE user_devices SET facebook_connected=false WHERE id=$1`, device)
		if _, err = s.handle(c, "fetch-event", receipt); err != nil {
			t.Fatal("receipt incorrectly requires Facebook", err)
		}
		exec(t, `DELETE FROM user_listing_alerts WHERE id=$1`, id)
		var count int
		if err = pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_background_fetch_attempts WHERE id=$1`, attempt).Scan(&count); err != nil || count != 0 {
			t.Fatal("trace did not cascade", err)
		}
	})

	t.Run("foreground completion cannot be credited to a late background upload", func(t *testing.T) {
		s, c, _, _, p, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		attempt := p.sent[0]["fetch_attempt_id"].(string)
		background, err := s.handle(c, "work", alertRequest{FetchAttemptID: attempt, Trigger: "background_push"})
		if err != nil {
			t.Fatal(err)
		}
		foreground, err := s.handle(c, "work", alertRequest{Trigger: "foreground"})
		if err != nil {
			t.Fatal(err)
		}
		bg := background.(map[string]any)["work"].([]alertWork)[0]
		fg := foreground.(map[string]any)["work"].([]alertWork)[0]
		upload := alertRequest{CheckID: fg.ID, FetchAttemptID: fg.FetchAttemptID, Actor: "123", Complete: true}
		if _, err = s.handle(c, "page", upload); err != nil {
			t.Fatal(err)
		}
		upload.FetchAttemptID = bg.FetchAttemptID
		if _, err = s.handle(c, "page", upload); connect.CodeOf(err) != connect.CodeAborted {
			t.Fatalf("accepted competing upload: %v", err)
		}
		var uncredited, emptyUpload bool
		if err = pool.QueryRow(ctx, `SELECT upload_received_at IS NULL FROM listing_alert_background_fetch_attempts WHERE id=$1`, bg.FetchAttemptID).Scan(&uncredited); err != nil || !uncredited {
			t.Fatal("misattributed background response", err)
		}
		if err = pool.QueryRow(ctx, `SELECT upload_received_at IS NOT NULL AND returned_listings='[]'::jsonb FROM listing_alert_background_fetch_attempts WHERE id=$1`, fg.FetchAttemptID).Scan(&emptyUpload); err != nil || !emptyUpload {
			t.Fatal("empty upload not recorded", err)
		}
	})

	t.Run("background retries retain each send and device failure", func(t *testing.T) {
		s, c, _, device, p, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		first := p.sent[0]["fetch_attempt_id"].(string)
		check := p.sent[0]["check_id"].(string)
		exec(t, `UPDATE listing_alert_check_runs SET last_push_at=now()-interval '31 minutes',next_push_at=now() WHERE id=$1`, check)
		exec(t, `UPDATE listing_alert_worker_clock SET next_dispatch_at=now() WHERE id=1`)
		p.fail = true
		if err := s.dispatch(ctx, 30*time.Second); err == nil {
			t.Fatal("expected send failure")
		}
		var count, accepted, failed int
		err := pool.QueryRow(ctx, `SELECT count(*),count(apns_accepted_at),count(*) FILTER(WHERE send_error='transport_error' AND send_finished_at IS NOT NULL) FROM listing_alert_background_fetch_attempts WHERE check_id=$1`, check).Scan(&count, &accepted, &failed)
		if err != nil || count != 2 || accepted != 1 || failed != 1 {
			t.Fatalf("attempt history lost: %d %d %d %v", count, accepted, failed, err)
		}
		exec(t, `UPDATE user_devices SET facebook_connected=false WHERE id=$1`, device)
		if _, err = s.handle(c, "fetch-event", alertRequest{FetchAttemptID: first, Event: "failed", FailureStage: "eligibility", FailureCode: "facebook_disconnected"}); err != nil {
			t.Fatal(err)
		}
		var recorded bool
		if err = pool.QueryRow(ctx, `SELECT failure_at IS NOT NULL AND failure_stage='eligibility' AND failure_code='facebook_disconnected' FROM listing_alert_background_fetch_attempts WHERE id=$1`, first).Scan(&recorded); err != nil || !recorded {
			t.Fatal("missing device failure", err)
		}
	})

	t.Run("visible notification is claimed once across workers", func(t *testing.T) {
		s, c, _, _, p, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		w := getWork(t, s, c)[0]
		if _, err := s.handle(c, "page", alertRequest{CheckID: w.ID, Actor: "123", Complete: true, Listings: []alertListing{{ID: "301", Title: "Switch OLED"}}}); err != nil {
			t.Fatal(err)
		}
		if err := s.evaluateBatch(ctx); err != nil {
			t.Fatal(err)
		}
		var wg sync.WaitGroup
		for range 8 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if err := s.notifyMatches(ctx); err != nil {
					t.Error(err)
				}
			}()
		}
		wg.Wait()
		if len(p.sent) != 2 {
			t.Fatalf("visible push count: %d", len(p.sent)-1)
		}
		var recorded bool
		if err := pool.QueryRow(ctx, `SELECT send_started_at IS NOT NULL AND send_finished_at IS NOT NULL AND sent_at IS NOT NULL AND send_error IS NULL FROM listing_alert_notification_outbox WHERE check_id=$1`, w.ID).Scan(&recorded); err != nil || !recorded {
			t.Fatal("accepted notification outcome missing", err)
		}
	})

	t.Run("eligibility ownership and session binding", func(t *testing.T) {
		s, c, _, device, _, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_devices SET notification_permission_status='DISABLED' WHERE id=$1`, device)
		_, err := s.handle(c, "create", alertRequest{Query: "A product", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}})
		if connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("permission gate: %v", err)
		}
		_, other, _, _, _, _ := fixture(t)
		_, err = s.handle(other, "delete", alertRequest{ID: id})
		if connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross-account deletion: %v", err)
		}
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		var count int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_check_runs WHERE alert_id=$1`, id).Scan(&count)
		if count != 0 {
			t.Fatal("dispatched disabled device")
		}
	})
	t.Run("dedup matches viewed retries and daily checks", func(t *testing.T) {
		s, c, user, _, p, e := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		work := getWork(t, s, c)
		if len(work) != 1 || len(p.sent) != 1 {
			t.Fatal("expected one check and silent push")
		}
		in := alertRequest{CheckID: work[0].ID, Actor: "123", Complete: true, Listings: []alertListing{{ID: "100", Title: "Switch OLED", PriceText: "$150"}, {ID: "101", Title: "wrong product"}}}
		if _, err := s.handle(c, "page", in); err != nil {
			t.Fatal(err)
		}
		if _, err := s.handle(c, "page", in); err != nil {
			t.Fatal("idempotent upload", err)
		}
		if err := s.evaluateBatch(ctx); err != nil {
			t.Fatal(err)
		}
		if len(e.inputs) != 1 || len(e.inputs[0].Candidates) != 2 || !e.inputs[0].Requirements {
			t.Fatal("wrong Jev input")
		}
		if err := s.notifyMatches(ctx); err != nil {
			t.Fatal(err)
		}
		if err := s.notifyMatches(ctx); err != nil {
			t.Fatal(err)
		}
		if len(p.sent) != 2 {
			t.Fatalf("duplicate or missing visible push: %d", len(p.sent))
		}
		matches, err := s.handle(c, "matches", alertRequest{ID: id})
		if err != nil {
			t.Fatal(err)
		}
		if len(matches.(map[string]any)["matches"].([]any)) != 1 {
			t.Fatal("wrong matches")
		}
		if _, err = s.handle(c, "viewed", alertRequest{ID: id, ListingIDs: []string{"100"}}); err != nil {
			t.Fatal(err)
		}
		var viewed *time.Time
		_ = pool.QueryRow(ctx, `SELECT viewed_at FROM listing_alert_listings WHERE alert_id=$1 AND listing_id='100'`, id).Scan(&viewed)
		if viewed == nil {
			t.Fatal("view not persisted")
		}
		dispatch(t, s)
		if len(getWork(t, s, c)) != 0 {
			t.Fatal("checked before the next daily schedule")
		}
		exec(t, `UPDATE user_listing_alerts SET last_checked_at=now()-interval '25 hours',next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		work = getWork(t, s, c)
		if len(work) != 1 {
			t.Fatal("daily work missing")
		}
		in.CheckID = work[0].ID
		in.Listings = append(in.Listings, alertListing{ID: "102", Title: "Switch OLED new"})
		if _, err = s.handle(c, "page", in); err != nil {
			t.Fatal(err)
		}
		if err = s.evaluateBatch(ctx); err != nil {
			t.Fatal(err)
		}
		if len(e.inputs) != 2 || len(e.inputs[1].Candidates) != 1 || e.inputs[1].Candidates[0].ID != "102" {
			t.Fatal("reevaluated old matched/rejected listings")
		}
		p.fail = true
		if err := s.notifyMatches(ctx); err == nil {
			t.Fatal("expected APNs failure")
		}
		p.fail = false
		if err := s.notifyMatches(ctx); err != nil {
			t.Fatal(err)
		}
		if len(p.sent) != 2 {
			t.Fatal("retried a visible notification")
		}
		var recorded bool
		if err := pool.QueryRow(ctx, `SELECT send_started_at IS NOT NULL AND send_finished_at IS NOT NULL AND send_error='transport_error' AND sent_at IS NULL FROM listing_alert_notification_outbox WHERE check_id=$1`, in.CheckID).Scan(&recorded); err != nil || !recorded {
			t.Fatalf("failed notification outcome missing: %v", err)
		}
		exec(t, `DELETE FROM user_listing_alerts WHERE user_id=$1`, user)
		var remaining int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_listings WHERE alert_id=$1`, id).Scan(&remaining)
		if remaining != 0 {
			t.Fatal("delete did not cascade")
		}
	})
	for _, traced := range []bool{false, true} {
		t.Run(fmt.Sprintf("one page candidate budget traced=%t", traced), func(t *testing.T) {
			s, c, _, _, _, evaluator := fixture(t)
			id := create(t, s, c)
			exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
			dispatch(t, s)
			work := getWork(t, s, c)[0]
			if traced {
				result, err := s.handle(c, "work", alertRequest{Trigger: "foreground"})
				if err != nil {
					t.Fatal(err)
				}
				work = result.(map[string]any)["work"].([]alertWork)[0]
			}
			upload := alertRequest{CheckID: work.ID, Actor: "123", Complete: true}
			if traced {
				if work.FetchAttemptID == "" {
					t.Fatal("missing fetch trace")
				}
				upload.FetchAttemptID = work.FetchAttemptID
			}
			for i := 0; i < 100; i++ {
				upload.Listings = append(upload.Listings, alertListing{ID: fmt.Sprint(1000 + i), Title: "Switch OLED"})
			}
			cursor := "another-page"
			for _, change := range []func(*alertRequest){
				func(r *alertRequest) { r.Complete = false; r.Cursor = &cursor },
				func(r *alertRequest) { r.Complete = false },
				func(r *alertRequest) { r.Cursor = &cursor },
				func(r *alertRequest) { r.Listings = append(r.Listings, alertListing{ID: "9999", Title: "Switch OLED"}) },
			} {
				invalid := upload
				change(&invalid)
				if _, err := s.handle(c, "page", invalid); connect.CodeOf(err) != connect.CodeInvalidArgument {
					t.Fatalf("accepted invalid upload: %v", err)
				}
			}
			var untouched bool
			if err := pool.QueryRow(ctx, `SELECT page_number=0 AND NOT scan_complete AND NOT EXISTS(SELECT 1 FROM listing_alert_listings WHERE check_id=$1) FROM listing_alert_check_runs WHERE id=$1`, work.ID).Scan(&untouched); err != nil || !untouched {
				t.Fatal("rejected uploads changed check", err)
			}
			if _, err := s.handle(c, "page", upload); err != nil {
				t.Fatal(err)
			}
			// Replaying page zero with fresh IDs must not append candidates.
			upload.Listings = []alertListing{{ID: "9999", Title: "Switch OLED"}}
			if _, err := s.handle(c, "page", upload); err != nil {
				t.Fatal("upload retry failed", err)
			}
			upload.PageNumber = 1
			if _, err := s.handle(c, "page", upload); connect.CodeOf(err) != connect.CodeAborted {
				t.Fatalf("accepted second page: %v", err)
			}
			var bounded bool
			if err := pool.QueryRow(ctx, `SELECT scan_complete AND cursor IS NULL AND page_number=1 AND (SELECT count(*) FROM listing_alert_listings WHERE check_id=$1)=100 AND NOT EXISTS(SELECT 1 FROM listing_alert_listings WHERE check_id=$1 AND listing_id='9999') FROM listing_alert_check_runs WHERE id=$1`, work.ID).Scan(&bounded); err != nil || !bounded {
				t.Fatal("candidate limit bypassed", err)
			}
			for i := 0; i < 6; i++ {
				if err := s.evaluateBatch(ctx); err != nil {
					t.Fatal(err)
				}
			}
			candidates := 0
			for _, input := range evaluator.inputs {
				candidates += len(input.Candidates)
			}
			if len(evaluator.inputs) != 4 || candidates != 100 {
				t.Fatalf("unbounded evaluation: calls=%d candidates=%d", len(evaluator.inputs), candidates)
			}
		})
	}

	t.Run("concurrent untraced uploads share one page budget", func(t *testing.T) {
		s, c, _, _, _, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		work := getWork(t, s, c)[0]
		start := make(chan struct{})
		results := make(chan error, 2)
		for batch := 0; batch < 2; batch++ {
			upload := alertRequest{CheckID: work.ID, Actor: "123", Complete: true}
			for i := 0; i < 100; i++ {
				upload.Listings = append(upload.Listings, alertListing{ID: fmt.Sprint(1000 + batch*100 + i), Title: "Switch OLED"})
			}
			go func() {
				<-start
				_, err := s.handle(c, "page", upload)
				results <- err
			}()
		}
		close(start)
		for i := 0; i < 2; i++ {
			if err := <-results; err != nil {
				t.Fatal(err)
			}
		}
		var count int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_listings WHERE check_id=$1`, work.ID).Scan(&count); err != nil || count != 100 {
			t.Fatalf("concurrent uploads stored %d candidates: %v", count, err)
		}
	})

	t.Run("candidate budget includes previously stored partial scan", func(t *testing.T) {
		s, c, _, _, _, _ := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		work := getWork(t, s, c)[0]
		exec(t, `UPDATE listing_alert_check_runs SET page_number=1,cursor='legacy-cursor' WHERE id=$1`, work.ID)
		exec(t, `INSERT INTO listing_alert_listings(alert_id,check_id,listing_id,listing) VALUES($1,$2,'9999','{"id":"9999","title":"Switch OLED"}')`, id, work.ID)
		upload := alertRequest{CheckID: work.ID, PageNumber: 1, Actor: "123", Complete: true}
		for i := 0; i < 100; i++ {
			upload.Listings = append(upload.Listings, alertListing{ID: fmt.Sprint(1000 + i), Title: "Switch OLED"})
		}
		if _, err := s.handle(c, "page", upload); connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("ignored stored candidates: %v", err)
		}
		upload.Listings = upload.Listings[:99]
		if _, err := s.handle(c, "page", upload); err != nil {
			t.Fatal(err)
		}
		var bounded bool
		if err := pool.QueryRow(ctx, `SELECT scan_complete AND cursor IS NULL AND (SELECT count(*) FROM listing_alert_listings WHERE check_id=$1)=100 FROM listing_alert_check_runs WHERE id=$1`, work.ID).Scan(&bounded); err != nil || !bounded {
			t.Fatal("partial scan exceeded budget or remained open", err)
		}
	})
	t.Run("resume invalidates stale uploads and preserves evaluation failures", func(t *testing.T) {
		s, c, _, _, _, e := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		w := getWork(t, s, c)[0]
		in := alertRequest{CheckID: w.ID, Actor: "123", Complete: true, Listings: []alertListing{{ID: "200", Title: "Switch OLED"}}}
		if _, err := s.handle(c, "state", alertRequest{ID: id, Paused: true}); err != nil {
			t.Fatal(err)
		}
		if _, err := s.handle(c, "state", alertRequest{ID: id, Paused: false}); err != nil {
			t.Fatal(err)
		}
		w = getWork(t, s, c)[0]
		if w.PageNumber != 1 || w.Cursor != nil || w.Actor != nil {
			t.Fatal("resume did not invalidate previous work")
		}
		if _, err := s.handle(c, "page", in); err != nil {
			t.Fatal(err)
		}
		var count int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_listings WHERE check_id=$1`, w.ID).Scan(&count); err != nil || count != 0 {
			t.Fatal("stale upload stored candidates", err)
		}
		in.PageNumber = w.PageNumber
		if _, err := s.handle(c, "page", in); err != nil {
			t.Fatal(err)
		}
		e.fail = true
		if err := s.evaluateBatch(ctx); err == nil {
			t.Fatal("expected evaluator error")
		}
		var checked *time.Time
		_ = pool.QueryRow(ctx, `SELECT checked_at FROM listing_alert_listings WHERE alert_id=$1`, id).Scan(&checked)
		if checked != nil {
			t.Fatal("failed evaluation marked checked")
		}
		if _, err := s.handle(c, "state", alertRequest{ID: id, Paused: true}); err != nil {
			t.Fatal(err)
		}
		if len(getWork(t, s, c)) != 0 {
			t.Fatal("paused check still offered")
		}
		if _, err := s.handle(c, "state", alertRequest{ID: id, Paused: false}); err != nil {
			t.Fatal(err)
		}
		if len(getWork(t, s, c)) != 0 {
			t.Fatal("resume reopened a completed scan")
		}
	})
	t.Run("notification groups and exact batch navigation", func(t *testing.T) {
		s, c, _, _, _, _ := fixture(t)
		alert := create(t, s, c)
		var groupIDs []string
		for batch := 0; batch < 53; batch++ {
			var check, notification string
			if err := pool.QueryRow(ctx, `INSERT INTO listing_alert_check_runs(alert_id,scan_complete,completed_at) VALUES($1,true,now()) RETURNING id`, alert).Scan(&check); err != nil {
				t.Fatal(err)
			}
			count := 1
			if batch == 52 {
				count = 13
			}
			listingIDs := []string{}
			for index := 0; index < count; index++ {
				id := fmt.Sprint(10000 + batch*100 + index)
				listingIDs = append(listingIDs, id)
				raw, _ := json.Marshal(alertListing{ID: id, Title: "Anthurium"})
				exec(t, `INSERT INTO listing_alert_listings(alert_id,listing_id,check_id,listing,matched,matched_at) VALUES($1,$2,$3,$4,true,'2026-10-17T12:34:56.123456Z')`, alert, id, check, raw)
			}
			if err := pool.QueryRow(ctx, `INSERT INTO listing_alert_notification_outbox(alert_id,check_id,listing_ids,created_at) VALUES($1,$2,$3,'2026-10-17T12:34:56.123456Z') RETURNING id`, alert, check, listingIDs).Scan(&notification); err != nil {
				t.Fatal(err)
			}
			groupIDs = append(groupIDs, notification)
		}
		exec(t, `UPDATE user_listing_alerts SET paused=true WHERE id=$1`, alert)
		request := alertRequest{}
		seen := map[string]bool{}
		for page := 0; page < 2; page++ {
			result, err := s.handle(c, "notification-feed", request)
			if err != nil {
				t.Fatal(err)
			}
			groups := result.(map[string]any)["groups"].([]alertNotificationGroup)
			expected := 50
			if page == 1 {
				expected = 3
			}
			if len(groups) != expected {
				t.Fatalf("page %d groups=%d", page, len(groups))
			}
			for _, group := range groups {
				if group.SeenAt != nil {
					t.Fatal("new batch inherited another batch's seen status")
				}
				if seen[group.ID] {
					t.Fatal("duplicate notification")
				}
				seen[group.ID] = true
				var previews []alertListing
				if err := json.Unmarshal(group.Previews, &previews); err != nil {
					t.Fatal(err)
				}
				if group.ID == groupIDs[52] && (group.MatchCount != 13 || group.UnreadCount != 13 || len(previews) != 4) {
					t.Fatalf("wrong grouped preview %+v", group)
				}
				if group.CreatedCursor != "2026-10-17T12:34:56.123456Z" {
					t.Fatal("lost cursor precision")
				}
				request = alertRequest{Before: &group.CreatedAt, BeforeID: group.ID}
			}
		}
		if len(seen) != 53 {
			t.Fatal("missing batches")
		}
		_, other, _, _, _, _ := fixture(t)
		result, err := s.handle(other, "notification-feed", alertRequest{})
		if err != nil {
			t.Fatal(err)
		}
		if len(result.(map[string]any)["groups"].([]alertNotificationGroup)) != 0 {
			t.Fatal("cross-user feed")
		}
		batchRequest := alertRequest{ID: alert, NotificationID: groupIDs[52]}
		result, err = s.handle(c, "matches", batchRequest)
		if err != nil {
			t.Fatal(err)
		}
		matches := result.(map[string]any)["matches"].([]any)
		if len(matches) != 13 {
			t.Fatalf("batch leaked other matches: %d", len(matches))
		}
		if result.(map[string]any)["notification"].(*alertNotificationDetails).ID != groupIDs[52] {
			t.Fatal("wrong metadata")
		}
		batchRequest.NotificationID = groupIDs[0]
		result, err = s.handle(c, "matches", batchRequest)
		if err != nil {
			t.Fatal(err)
		}
		if len(result.(map[string]any)["matches"].([]any)) != 1 {
			t.Fatal("single batch leaked matches")
		}
		if _, err = s.handle(other, "matches", batchRequest); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross-account batch: %v", err)
		}
		wrongAlert := create(t, s, c)
		batchRequest.ID = wrongAlert
		if _, err = s.handle(c, "matches", batchRequest); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross-alert batch: %v", err)
		}
		click := alertRequest{ID: alert, NotificationID: groupIDs[52], Source: "alerts_tab", Event: "listing_opened", InteractionID: uuid.NewString(), ListingID: "15200"}
		if _, err = s.handle(c, "interaction", click); err != nil {
			t.Fatal(err)
		}
		click.ListingID = "10000"
		click.InteractionID = uuid.NewString()
		if _, err = s.handle(c, "interaction", click); connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("cross-batch click: %v", err)
		}
		var source, notification string
		if err := pool.QueryRow(ctx, `SELECT source,notification_id FROM listing_alert_interactions WHERE alert_id=$1 AND listing_id='15200'`, alert).Scan(&source, &notification); err != nil || source != "alerts_tab" || notification != groupIDs[52] {
			t.Fatalf("lost click attribution: %v", err)
		}
	})

	t.Run("recent feed combines owned alerts with stable pagination", func(t *testing.T) {
		s, c, _, _, _, _ := fixture(t)
		ids := []string{create(t, s, c), create(t, s, c)}
		for _, id := range ids {
			var check uuid.UUID
			if err := pool.QueryRow(ctx, `INSERT INTO listing_alert_check_runs(alert_id) VALUES($1) RETURNING id`, id).Scan(&check); err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 28; i++ {
				l := alertListing{ID: fmt.Sprint(1000 + i), Title: "Match"}
				raw, _ := json.Marshal(l)
				exec(t, `INSERT INTO listing_alert_listings(alert_id,listing_id,check_id,listing,matched,matched_at) VALUES($1,$2,$3,$4,$5,'2026-10-17T12:34:56.123456Z')`, id, l.ID, check, raw, i < 27)
			}
		}
		exec(t, `UPDATE user_listing_alerts SET paused=true WHERE id=$1`, ids[0])
		exec(t, `UPDATE listing_alert_listings SET viewed_at=now() WHERE alert_id=$1 AND listing_id='1000'`, ids[0])
		seen := map[string]bool{}
		request := alertRequest{}
		viewed := 0
		for page := 0; page < 2; page++ {
			result, err := s.handle(c, "feed", request)
			if err != nil {
				t.Fatal(err)
			}
			items := result.(map[string]any)["items"].([]alertFeedItem)
			expected := 50
			if page == 1 {
				expected = 4
			}
			if len(items) != expected {
				t.Fatalf("page %d count %d", page, len(items))
			}
			for _, item := range items {
				var listing alertListing
				if err := json.Unmarshal(item.Match.Listing, &listing); err != nil {
					t.Fatal(err)
				}
				key := item.AlertID + ":" + listing.ID
				if seen[key] {
					t.Fatal("repeated feed item")
				}
				seen[key] = true
				if item.Match.ViewedAt != nil {
					viewed++
				}
				if item.Match.MatchedCursor != "2026-10-17T12:34:56.123456Z" {
					t.Fatal("lost cursor precision")
				}
				request = alertRequest{Before: &item.Match.MatchedAt, BeforeAlertID: item.AlertID, BeforeID: listing.ID}
			}
		}
		if len(seen) != 54 || viewed != 1 {
			t.Fatalf("missing feed state %d %d", len(seen), viewed)
		}
		_, other, _, _, _, _ := fixture(t)
		result, err := s.handle(other, "feed", alertRequest{})
		if err != nil {
			t.Fatal(err)
		}
		if len(result.(map[string]any)["items"].([]alertFeedItem)) != 0 {
			t.Fatal("cross-account feed")
		}
		request.BeforeAlertID = "bad"
		if _, err := s.handle(c, "feed", request); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("invalid cursor: %v", err)
		}
	})

	t.Run("stable match pagination and account isolation", func(t *testing.T) {
		s, c, _, _, _, _ := fixture(t)
		id := create(t, s, c)
		var check uuid.UUID
		if err := pool.QueryRow(ctx, `INSERT INTO listing_alert_check_runs(alert_id) VALUES($1) RETURNING id`, id).Scan(&check); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 105; i++ {
			l := alertListing{ID: fmt.Sprint(1000 + i), Title: "Match"}
			raw, _ := json.Marshal(l)
			exec(t, `INSERT INTO listing_alert_listings(alert_id,listing_id,check_id,listing,matched,matched_at) VALUES($1,$2,$3,$4,true,'2026-10-01T12:34:56.123456Z')`, id, l.ID, check, raw)
		}
		result, err := s.handle(c, "matches", alertRequest{ID: id})
		if err != nil {
			t.Fatal(err)
		}
		first := result.(map[string]any)["matches"].([]any)
		if len(first) != 100 {
			t.Fatal("missing first page")
		}
		last := first[99].(map[string]any)
		var listing alertListing
		_ = json.Unmarshal(last["listing"].(json.RawMessage), &listing)
		before := last["matchedAt"].(time.Time)
		result, err = s.handle(c, "matches", alertRequest{ID: id, Before: &before, BeforeID: listing.ID})
		if err != nil {
			t.Fatal(err)
		}
		if len(result.(map[string]any)["matches"].([]any)) != 5 {
			t.Fatal("timestamp ties dropped matches")
		}
		_, other, _, _, _, _ := fixture(t)
		result, err = s.handle(other, "matches", alertRequest{ID: id})
		if err != nil {
			t.Fatal(err)
		}
		if len(result.(map[string]any)["matches"].([]any)) != 0 {
			t.Fatal("cross-user read")
		}
		if _, err = s.handle(other, "viewed", alertRequest{ID: id, ListingIDs: []string{"1000"}}); err != nil {
			t.Fatal(err)
		}
		var seen int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM listing_alert_listings WHERE alert_id=$1 AND viewed_at IS NOT NULL`, id).Scan(&seen)
		if seen != 0 {
			t.Fatal("cross-user view write")
		}
	})
}

func TestListingAlertMigrationUpgradesMain(t *testing.T) {
	dsn := os.Getenv("ALERTS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set ALERTS_TEST_DATABASE_URL to a disposable Postgres 18 database")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	schema := "alerts_migration_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
	}()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sqlDB := stdlib.OpenDBFromPool(pool)
	defer sqlDB.Close()
	goose.SetLogger(goose.NopLogger())
	if err = goose.SetDialect("postgres"); err != nil {
		t.Fatal(err)
	}
	const migrations = "../../deployments/migrations"
	if err = goose.UpTo(sqlDB, migrations, 23); err != nil {
		t.Fatal(err)
	}
	var user, listing uuid.UUID
	if err = pool.QueryRow(ctx, `INSERT INTO users(first_name,email) VALUES('Migration test','migration@example.test') RETURNING id`).Scan(&user); err != nil {
		t.Fatal(err)
	}
	if err = pool.QueryRow(ctx, `INSERT INTO listings(facebook_listing_id,snapshot,last_viewed_by,last_viewed_at,price_amount,price_currency_code,original_price_amount) VALUES('123456789','{"title":"Existing saved listing"}',$1,now(),123.45,'CAD',150.00) RETURNING id`, user).Scan(&listing); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `INSERT INTO saved_listings(user_id,listing_id,saved_at) VALUES($1,$2,now())`, user, listing); err != nil {
		t.Fatal(err)
	}
	var session uuid.UUID
	if err = pool.QueryRow(ctx, `INSERT INTO user_sessions(user_id,device_platform,refresh_token_hash,refresh_token_expires_at) VALUES($1,'IOS','migration-session',now()+interval '1 day') RETURNING id`, user).Scan(&session); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `INSERT INTO sign_in_challenges(nonce_hash,auth_service,install_id,linking_session_id) VALUES('migration-challenge','APPLE','migration-install',$1)`, session); err != nil {
		t.Fatal(err)
	}
	assertMainData := func() {
		t.Helper()
		var count int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM saved_listings s JOIN listings l ON l.id=s.listing_id JOIN users u ON u.id=s.user_id WHERE u.id=$1 AND u.first_name='Migration test' AND u.email='migration@example.test' AND l.id=$2 AND l.last_viewed_by=u.id AND l.snapshot->>'title'='Existing saved listing' AND l.price_amount=123.45 AND l.price_currency_code='CAD' AND l.original_price_amount=150.00`, user, listing).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 1 {
			t.Fatal("main's account, saved listing, price, or view data changed")
		}
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM sign_in_challenges c JOIN user_sessions s ON s.id=c.linking_session_id WHERE c.nonce_hash='migration-challenge' AND c.auth_service='APPLE' AND c.install_id='migration-install' AND s.id=$1 AND s.user_id=$2`, session, user).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 1 {
			t.Fatal("main's sign-in linking data changed")
		}
	}
	if err = goose.UpTo(sqlDB, migrations, 24); err != nil {
		t.Fatal(err)
	}
	var legacyAlert uuid.UUID
	err = pool.QueryRow(ctx, `WITH device AS (INSERT INTO user_devices(user_id,install_id,platform) VALUES($1,'migration-device','IOS') RETURNING id)
        INSERT INTO user_listing_alerts(user_id,device_id,query,location,alert_hour,next_check_at) SELECT $1,id,'Legacy alert','{}',0,now() FROM device RETURNING id`, user).Scan(&legacyAlert)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		_, err = pool.Exec(ctx, `WITH run AS (INSERT INTO listing_alert_check_runs(alert_id,completed_at) VALUES($1,now()) RETURNING id)
            INSERT INTO listing_alert_notification_outbox(alert_id,check_id,listing_ids,attempts,sent_at)
            SELECT $1,id,ARRAY['123'],CASE WHEN $2::int=0 THEN 0 ELSE 1 END,CASE WHEN $2::int=2 THEN now() END FROM run`, legacyAlert, i)
		if err != nil {
			t.Fatal(err)
		}
	}
	if err = goose.Up(sqlDB, migrations); err != nil {
		t.Fatal(err)
	}
	var pending, succeeded, unknown int
	err = pool.QueryRow(ctx, `SELECT count(*) FILTER(WHERE send_started_at IS NULL),count(sent_at),count(*) FILTER(WHERE send_error='legacy_outcome_unknown' AND send_started_at IS NOT NULL) FROM listing_alert_notification_outbox WHERE alert_id=$1`, legacyAlert).Scan(&pending, &succeeded, &unknown)
	if err != nil || pending != 1 || succeeded != 1 || unknown != 1 {
		t.Fatalf("legacy notification migration: %d/%d/%d %v", pending, succeeded, unknown, err)
	}
	var preserved bool
	if err = pool.QueryRow(ctx, `SELECT a.alert_hour=0 AND a.alert_minute=0 AND a.time_zone='UTC' AND a.min_price IS NULL AND a.max_price IS NULL AND NOT a.paused AND u.listing_alert_bonus_slots=0 FROM user_listing_alerts a JOIN users u ON u.id=a.user_id WHERE a.id=$1`, legacyAlert).Scan(&preserved); err != nil || !preserved {
		t.Fatal("legacy alert or initial allowance changed", err)
	}
	if version, err := goose.GetDBVersion(sqlDB); err != nil || version != 32 {
		t.Fatalf("migration version = %d, error = %v", version, err)
	}
	assertMainData()
	var alertTable *string
	if err = pool.QueryRow(ctx, `SELECT to_regclass('user_listing_alerts')::text`).Scan(&alertTable); err != nil || alertTable == nil {
		t.Fatalf("missing alerts table: %v", err)
	}
	if err = goose.DownTo(sqlDB, migrations, 23); err != nil {
		t.Fatal(err)
	}
	assertMainData()
	if err = pool.QueryRow(ctx, `SELECT to_regclass('user_listing_alerts')::text`).Scan(&alertTable); err != nil || alertTable != nil {
		t.Fatalf("alerts rollback failed: %v", err)
	}
	if err = goose.Up(sqlDB, migrations); err != nil {
		t.Fatal(err)
	}
	assertMainData()
}
