package verify

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestPrelude(t *testing.T, handler http.HandlerFunc) *PreludeSender {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)

	sender, err := NewPreludeSender(PreludeOptions{
		APIKey:     "sk_test",
		BaseURL:    srv.URL,
		HTTPClient: srv.Client(),
	})
	if err != nil {
		t.Fatalf("NewPreludeSender: %v", err)
	}
	return sender
}

func TestNewPreludeSenderRequiresAPIKey(t *testing.T) {
	if _, err := NewPreludeSender(PreludeOptions{}); err == nil {
		t.Fatal("NewPreludeSender without a key = nil error, want error")
	}
}

func TestPreludeStartSendsBearerAndTarget(t *testing.T) {
	var gotPath, gotAuth string
	var body preludeCreateRequest
	sender := newTestPrelude(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		_, _ = w.Write([]byte(`{"status":"success"}`))
	})

	err := sender.Start(context.Background(), "+14155550123", Signals{
		DeviceID:       "install-abcdefgh",
		DevicePlatform: "ios",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if gotPath != "/v2/verification" {
		t.Fatalf("path = %q", gotPath)
	}
	// Bearer auth, and the thing that silently 401s in production if the header
	// is ever built by hand rather than here.
	if gotAuth != "Bearer sk_test" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
	if body.Target.Type != "phone_number" || body.Target.Value != "+14155550123" {
		t.Fatalf("target = %+v", body.Target)
	}
	if body.Signals == nil ||
		body.Signals.DeviceID != "install-abcdefgh" ||
		body.Signals.DevicePlatform != "ios" {
		t.Fatalf("signals = %+v", body.Signals)
	}
}

// An empty signals object is a worse thing to send than none: it tells the
// scorer these are unavailable rather than that we didn't fill them in.
func TestPreludeStartOmitsEmptySignals(t *testing.T) {
	var raw map[string]any
	sender := newTestPrelude(t, func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &raw)
		_, _ = w.Write([]byte(`{"status":"success"}`))
	})

	if err := sender.Start(context.Background(), "+14155550123", Signals{}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if _, present := raw["signals"]; present {
		t.Fatalf("empty signals were sent: %v", raw)
	}
}

// Prelude reports a refused send as HTTP 200 with status "blocked" rather than
// as an error status. A sender that only inspects the status code would treat
// every one of these as a code successfully sent.
func TestPreludeStartClassifiesBlockedOn200(t *testing.T) {
	tests := []struct {
		reason string
		want   error
	}{
		{preludeInvalidPhoneNumber, ErrUndeliverable},
		{preludeInvalidPhoneLine, ErrUndeliverable},
		{preludeInBlockList, ErrUndeliverable},
		{preludeSuspicious, ErrUndeliverable},
		{preludeRepeatedAttempts, ErrTooManyAttempts},
	}
	for _, tc := range tests {
		t.Run(tc.reason, func(t *testing.T) {
			sender := newTestPrelude(t, func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(`{"status":"blocked","reason":"` + tc.reason + `"}`))
			})
			err := sender.Start(context.Background(), "+14155550123", Signals{})
			if !errors.Is(err, tc.want) {
				t.Fatalf("Start error = %v, want %v", err, tc.want)
			}
		})
	}
}

// retry is what a resend produces, and shadow_blocked means a dry-run rule
// matched but was not enforced. Both delivered a message; failing either would
// break login — shadow_blocked especially, since turning on a rule in dry-run
// mode is supposed to be the safe way to test it.
func TestPreludeStartAcceptsDeliveredStatuses(t *testing.T) {
	for _, status := range []string{
		preludeStatusSuccess,
		preludeStatusRetry,
		preludeStatusChallenged,
		preludeStatusShadowBlocked,
	} {
		t.Run(status, func(t *testing.T) {
			sender := newTestPrelude(t, func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(`{"status":"` + status + `"}`))
			})
			if err := sender.Start(context.Background(), "+14155550123", Signals{}); err != nil {
				t.Fatalf("Start on %q = %v, want nil", status, err)
			}
		})
	}
}

func TestPreludeStartRejectsUnknownStatus(t *testing.T) {
	sender := newTestPrelude(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"status":"something_new"}`))
	})
	if err := sender.Start(context.Background(), "+14155550123", Signals{}); err == nil {
		t.Fatal("unknown status = nil error, want error")
	}
}

// A 429 means the same thing whether or not the body parses, and the caller
// needs it distinguishable from an outage so it can say "try again later".
func TestPreludeStartMapsRateLimitWithUnreadableBody(t *testing.T) {
	sender := newTestPrelude(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`not json`))
	})
	err := sender.Start(context.Background(), "+14155550123", Signals{})
	if !errors.Is(err, ErrTooManyAttempts) {
		t.Fatalf("Start error = %v, want ErrTooManyAttempts", err)
	}
}

// An unrecognised provider error must not masquerade as one of the two
// conditions the caller reacts to, or a Prelude outage reads to the user as
// "that number can't receive texts".
func TestPreludeStartLeavesUnknownErrorsOpaque(t *testing.T) {
	sender := newTestPrelude(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"code":"internal_error","message":"boom"}`))
	})
	err := sender.Start(context.Background(), "+14155550123", Signals{})
	if err == nil {
		t.Fatal("Start = nil error, want error")
	}
	if errors.Is(err, ErrUndeliverable) || errors.Is(err, ErrTooManyAttempts) {
		t.Fatalf("unknown provider error was classified: %v", err)
	}
}

// Signature failures mean our own request was malformed. Reporting them as
// ErrUndeliverable would tell the user their number is bad when the bug is ours.
func TestPreludeStartDoesNotBlameTheNumberForOurBugs(t *testing.T) {
	for _, reason := range []string{"invalid_signature", "expired_signature"} {
		t.Run(reason, func(t *testing.T) {
			sender := newTestPrelude(t, func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(`{"status":"blocked","reason":"` + reason + `"}`))
			})
			err := sender.Start(context.Background(), "+14155550123", Signals{})
			if err == nil {
				t.Fatal("Start = nil error, want error")
			}
			if errors.Is(err, ErrUndeliverable) {
				t.Fatalf("%s was reported as undeliverable: %v", reason, err)
			}
		})
	}
}

func TestPreludeCheck(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		body       string
		want       Result
		wantErr    error
		wantNilErr bool
	}{
		{
			name: "success", status: 200, body: `{"status":"success"}`,
			want: ResultApproved, wantNilErr: true,
		},
		{
			name: "wrong code", status: 200, body: `{"status":"failure"}`,
			want: ResultDenied, wantNilErr: true,
		},
		{
			// Expired and wrong are the same answer to the person typing, and
			// distinguishing them tells an attacker whether a number has a
			// verification in flight.
			name: "expired is denied, not an error", status: 200,
			body: `{"status":"expired_or_not_found"}`,
			want: ResultDenied, wantNilErr: true,
		},
		{
			name: "too many checks", status: 429,
			body: `{"code":"too_many_checks","message":"slow down"}`,
			want: ResultDenied, wantErr: ErrTooManyAttempts,
		},
		{
			// PSD2-only, and we never issue a PSD2 code. Denying quietly would
			// hide a template change; this should be loud.
			name: "psd2 status is an error", status: 200,
			body: `{"status":"transaction_mismatch"}`,
			want: ResultDenied, wantErr: nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			sender := newTestPrelude(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v2/verification/check" {
					t.Errorf("path = %q", r.URL.Path)
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			})
			got, err := sender.Check(context.Background(), "+14155550123", "123456")
			if got != tc.want {
				t.Fatalf("Check result = %v, want %v", got, tc.want)
			}
			switch {
			case tc.wantNilErr && err != nil:
				t.Fatalf("Check error = %v, want nil", err)
			case tc.wantErr != nil && !errors.Is(err, tc.wantErr):
				t.Fatalf("Check error = %v, want %v", err, tc.wantErr)
			case !tc.wantNilErr && tc.wantErr == nil && err == nil:
				t.Fatal("Check error = nil, want an error")
			}
		})
	}
}
