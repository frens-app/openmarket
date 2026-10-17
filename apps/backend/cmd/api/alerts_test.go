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
		options, err := config.ParseAlertSearchOptions("")
		if err != nil {
			t.Fatal(err)
		}
		s := &alertsServer{searchOptions: options, pool: pool, queries: db.New(pool), push: p, evaluator: e, logger: zap.NewNop()}
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
		if err := pool.QueryRow(ctx, `SELECT created_at,next_check_at,alert_hour FROM user_listing_alerts WHERE user_id=$1 LIMIT 1`, user).Scan(&created, &next, &hour); err != nil {
			t.Fatal(err)
		}
		if !created.UTC().Round(time.Hour).Equal(next) || hour != next.UTC().Hour() {
			t.Fatal("schedule is not rounded creation time")
		}
		exec(t, `UPDATE user_listing_alerts SET paused=true WHERE user_id=$1`, user)
		_, err := s.handle(c, "create", alertRequest{Query: "Fourth alert", Location: alertLocation{CitySlug: "sf", RadiusKM: 16}})
		if connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("paused alerts escaped limit: %v", err)
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
		if len(initial) != 1 || initial[0].SearchOptions.Sort != "creation_time_descend" {
			t.Fatalf("default work: %+v", initial)
		}
		options, err := config.ParseAlertSearchOptions(`{"sort":"price_ascend","minPrice":10,"maxPrice":100,"daysSinceListed":1}`)
		if err != nil {
			t.Fatal(err)
		}
		s.searchOptions = options
		updated := getWork(t, s, c)
		if len(updated) != 1 || updated[0].ID != initial[0].ID || updated[0].SearchOptions.Sort != "price_ascend" || updated[0].SearchOptions.MaxPrice == nil || *updated[0].SearchOptions.MaxPrice != 100 || len(p.sent) != 1 {
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
		if v.(map[string]any)["work"].([]alertWork)[0].SearchOptions.Sort != "creation_time_descend" {
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
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
		dispatch(t, s)
		if len(getWork(t, s, c)) != 0 {
			t.Fatal("checked twice in 24 hours")
		}
		exec(t, `UPDATE user_listing_alerts SET last_checked_at=now()-interval '25 hours' WHERE id=$1`, id)
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
	t.Run("cursor resume stale uploads pause and evaluation failures", func(t *testing.T) {
		s, c, _, _, _, e := fixture(t)
		id := create(t, s, c)
		exec(t, `UPDATE user_listing_alerts SET next_check_at=now()-interval '1 hour' WHERE id=$1`, id)
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
		w = getWork(t, s, c)[0]
		if w.Cursor != nil || w.Actor != nil {
			t.Fatal("resume did not reset device cursor")
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

func TestPriceAlertMigrationUpgradesMain(t *testing.T) {
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
	if version, err := goose.GetDBVersion(sqlDB); err != nil || version != 25 {
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
