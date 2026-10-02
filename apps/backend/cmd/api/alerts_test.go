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
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/llm"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"go.uber.org/zap"
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
	for _, tc := range []struct{ timestamp, want string }{{"2026-10-01T19:29:59Z", "2026-10-01T19:00:00Z"}, {"2026-10-01T19:30:00Z", "2026-10-01T20:00:00Z"}, {"2026-10-01T23:45:00Z", "2026-10-02T00:00:00Z"}} {
		value, _ := time.Parse(time.RFC3339, tc.timestamp)
		if got := value.Round(time.Hour).Format(time.RFC3339); got != tc.want {
			t.Fatalf("round %s = %s", tc.timestamp, got)
		}
	}
}
func TestAlertsHTTPRequiresAuthentication(t *testing.T) {
	s := &alertsServer{logger: zap.NewNop()}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/v1/price-alerts/list", strings.NewReader(`{}`)))
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
		if err := pool.QueryRow(ctx, `INSERT INTO user_devices(user_id,install_id,platform,facebook_connected,push_token,notification_permission_status) VALUES($1,$2,'IOS',true,$3,'ENABLED') RETURNING id`, user, uuid.NewString(), uuid.NewString()).Scan(&device); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `INSERT INTO user_sessions(user_id,device_id,device_platform,refresh_token_hash,refresh_token_expires_at) VALUES($1,$2,'IOS',$3,now()+interval '1 day') RETURNING id`, user, device, uuid.NewString()).Scan(&session); err != nil {
			t.Fatal(err)
		}
		p := &fakeAlertPush{}
		e := &fakeAlertEvaluator{}
		s := &alertsServer{pool: pool, queries: db.New(pool), push: p, evaluator: e, logger: zap.NewNop()}
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
		exec(t, `UPDATE price_alert_worker_clock SET next_dispatch_at=now()-interval '1 minute'`)
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

	t.Run("concurrent limit and exact schedule", func(t *testing.T) {
		s, c, user, _, _, _ := fixture(t)
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
		if success != 3 || limited != 5 {
			t.Fatalf("success=%d limited=%d", success, limited)
		}
		var created, next time.Time
		var hour int
		if err := pool.QueryRow(ctx, `SELECT created_at,next_check_at,alert_hour FROM price_alerts WHERE user_id=$1 LIMIT 1`, user).Scan(&created, &next, &hour); err != nil {
			t.Fatal(err)
		}
		if !created.UTC().Round(time.Hour).Equal(next) || hour != next.UTC().Hour() {
			t.Fatal("schedule is not rounded creation time")
		}
		exec(t, `UPDATE price_alerts SET paused=true WHERE user_id=$1`, user)
		_, err := s.handle(c, "create", alertRequest{Query: "Fourth alert", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}})
		if connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("paused alerts escaped limit: %v", err)
		}
	})
	t.Run("replicas stagger oldest due work", func(t *testing.T) {
		s, c, _, _, p, _ := fixture(t)
		oldest := create(t, s, c)
		newest := create(t, s, c)
		exec(t, `UPDATE price_alerts SET next_check_at=now()-interval '1 hour' WHERE id=ANY($1::uuid[])`, []string{oldest, newest})
		exec(t, `UPDATE price_alerts SET created_at=created_at-interval '1 day' WHERE id=$1`, oldest)
		exec(t, `UPDATE price_alert_worker_clock SET next_dispatch_at=now()-interval '1 minute'`)
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
		exec(t, `UPDATE price_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		var count int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM price_alert_checks WHERE alert_id=$1`, id).Scan(&count)
		if count != 0 {
			t.Fatal("dispatched disabled device")
		}
	})
	t.Run("dedup matches viewed retries and daily checks", func(t *testing.T) {
		s, c, user, _, p, e := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE price_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
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
		p.fail = true
		if err := s.notifyMatches(ctx); err == nil {
			t.Fatal("expected APNs error")
		}
		p.fail = false
		exec(t, `UPDATE price_alert_notifications SET next_attempt_at=now() WHERE alert_id=$1`, id)
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
		_ = pool.QueryRow(ctx, `SELECT viewed_at FROM price_alert_listings WHERE alert_id=$1 AND listing_id='100'`, id).Scan(&viewed)
		if viewed == nil {
			t.Fatal("view not persisted")
		}
		exec(t, `UPDATE price_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		if len(getWork(t, s, c)) != 0 {
			t.Fatal("checked twice in 24 hours")
		}
		exec(t, `UPDATE price_alerts SET last_checked_at=now()-interval '25 hours' WHERE id=$1`, id)
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
		exec(t, `DELETE FROM price_alerts WHERE user_id=$1`, user)
		var remaining int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM price_alert_listings WHERE alert_id=$1`, id).Scan(&remaining)
		if remaining != 0 {
			t.Fatal("delete did not cascade")
		}
	})
	t.Run("cursor resume stale uploads pause and evaluation failures", func(t *testing.T) {
		s, c, _, _, _, e := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE price_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		w := getWork(t, s, c)[0]
		cursor := "page-2"
		in := alertRequest{CheckID: w.ID, Actor: "123", Cursor: &cursor, Listings: []alertListing{{ID: "200", Title: "Switch OLED"}}}
		if _, err := s.handle(c, "page", in); err != nil {
			t.Fatal(err)
		}
		w = getWork(t, s, c)[0]
		if w.PageNumber != 1 || *w.Cursor != cursor || *w.Actor != "123" {
			t.Fatal("cursor lost")
		}
		in.PageNumber = 1
		in.Actor = "456"
		if _, err := s.handle(c, "page", in); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatal("accepted different Facebook account")
		}
		e.fail = true
		if err := s.evaluateBatch(ctx); err == nil {
			t.Fatal("expected evaluator error")
		}
		var checked *time.Time
		_ = pool.QueryRow(ctx, `SELECT checked_at FROM price_alert_listings WHERE alert_id=$1`, id).Scan(&checked)
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
		w = getWork(t, s, c)[0]
		if w.Cursor != nil || w.Actor != nil {
			t.Fatal("resume did not reset device cursor")
		}
	})
	t.Run("stable match pagination and account isolation", func(t *testing.T) {
		s, c, _, _, _, _ := fixture(t)
		id := create(t, s, c)
		var check uuid.UUID
		if err := pool.QueryRow(ctx, `INSERT INTO price_alert_checks(alert_id) VALUES($1) RETURNING id`, id).Scan(&check); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 105; i++ {
			l := alertListing{ID: fmt.Sprint(1000 + i), Title: "Match"}
			raw, _ := json.Marshal(l)
			exec(t, `INSERT INTO price_alert_listings(alert_id,listing_id,check_id,listing,matched,matched_at) VALUES($1,$2,$3,$4,true,'2026-10-01T12:34:56.123456Z')`, id, l.ID, check, raw)
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
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM price_alert_listings WHERE alert_id=$1 AND viewed_at IS NOT NULL`, id).Scan(&seen)
		if seen != 0 {
			t.Fatal("cross-user view write")
		}
	})
}
