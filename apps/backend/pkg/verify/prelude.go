package verify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"go.uber.org/zap"
)

const (
	defaultPreludeBaseURL = "https://api.prelude.dev"
	preludeTimeout        = 10 * time.Second
	// Prelude's default. Configurable per request (options.code_size, 4-8) and
	// in the dashboard, so it is reported to the client rather than assumed by
	// it.
	preludeCodeLength = 6
)

// Statuses returned by POST /v2/verification.
const (
	// A new verification window was created.
	preludeStatusSuccess = "success"
	// A further attempt inside an existing window — what a resend produces.
	preludeStatusRetry = "retry"
	// Routed through a non-SMS channel because the request looked risky. A code
	// still went out, so it is a send from our point of view.
	preludeStatusChallenged = "challenged"
	// A block rule matched but was not enforced. Prelude's dry-run mode for
	// tuning rules: the message was delivered, so this must not fail the call,
	// or enabling a rule in dry-run would break login for real users.
	preludeStatusShadowBlocked = "shadow_blocked"
	// Nothing was sent.
	preludeStatusBlocked = "blocked"
)

// Statuses returned by POST /v2/verification/check.
const (
	preludeCheckSuccess           = "success"
	preludeCheckFailure           = "failure"
	preludeCheckExpiredOrNotFound = "expired_or_not_found"
)

// Reasons accompanying a blocked send, and the error codes on a 4xx body.
// Prelude's codes are strings, not numbers.
const (
	preludeInvalidPhoneNumber = "invalid_phone_number"
	preludeInvalidPhoneLine   = "invalid_phone_line"
	preludeInBlockList        = "in_block_list"
	preludeSuspicious         = "suspicious"
	preludeRepeatedAttempts   = "repeated_attempts"
	preludeRateLimited        = "rate_limited"
	preludeTooManyAttempts    = "too_many_attempts"
	preludeTooManyChecks      = "too_many_checks"
)

// PreludeSender talks to Prelude's Verify API.
//
// Two JSON POSTs is the entire integration, which is why there is no SDK
// dependency here — the official Go SDK is Stainless-generated and covers every
// product Prelude sells, to save about fifty lines.
//
// One thing about the shape is worth knowing before changing anything: **a
// refused send comes back as HTTP 200 with status "blocked"**, not as an error
// status. That is why Start inspects the body on success as well as on failure,
// and why a rewrite that only checks the status code would silently count every
// blocked number as a code delivered.
type PreludeSender struct {
	apiKey         string
	baseURL        string
	httpClient     *http.Client
	codeLengthHint int
	logger         *zap.Logger
}

// PreludeOptions configures the sender.
type PreludeOptions struct {
	APIKey string
	// BaseURL is for tests only — it is not wired to any configuration value, so
	// there is no way to point a running service at something that isn't
	// Prelude. Empty means the real API.
	BaseURL    string
	CodeLength int
	HTTPClient *http.Client
	// Logger records the status of every send. Optional; nil discards.
	Logger *zap.Logger
}

// NewPreludeSender builds a Prelude Verify client.
func NewPreludeSender(opts PreludeOptions) (*PreludeSender, error) {
	if strings.TrimSpace(opts.APIKey) == "" {
		return nil, fmt.Errorf("prelude api key is required")
	}
	base := strings.TrimSuffix(strings.TrimSpace(opts.BaseURL), "/")
	if base == "" {
		base = defaultPreludeBaseURL
	}
	codeLength := opts.CodeLength
	if codeLength <= 0 {
		codeLength = preludeCodeLength
	}
	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: preludeTimeout}
	}
	logger := opts.Logger
	if logger == nil {
		logger = zap.NewNop()
	}
	return &PreludeSender{
		apiKey:         opts.APIKey,
		baseURL:        base,
		httpClient:     client,
		codeLengthHint: codeLength,
		logger:         logger,
	}, nil
}

// CodeLength implements Sender.
func (p *PreludeSender) CodeLength() int { return p.codeLengthHint }

type preludeTarget struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}

type preludeSignals struct {
	DeviceID       string `json:"device_id,omitempty"`
	DevicePlatform string `json:"device_platform,omitempty"`
}

type preludeCreateRequest struct {
	Target  preludeTarget   `json:"target"`
	Signals *preludeSignals `json:"signals,omitempty"`
}

type preludeCheckRequest struct {
	Target preludeTarget `json:"target"`
	Code   string        `json:"code"`
}

type preludeResponse struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Reason string `json:"reason"`
}

type preludeErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Start implements Sender.
func (p *PreludeSender) Start(ctx context.Context, e164 string, signals Signals) error {
	body := preludeCreateRequest{
		Target: preludeTarget{Type: "phone_number", Value: e164},
	}
	// Sent only when we actually have something. An empty object would be worse
	// than no object: it is a signal to the scorer that these are unavailable,
	// when in fact we just didn't fill them in.
	if signals.DeviceID != "" || signals.DevicePlatform != "" {
		body.Signals = &preludeSignals{
			DeviceID:       signals.DeviceID,
			DevicePlatform: signals.DevicePlatform,
		}
	}

	var out preludeResponse
	if err := p.post(ctx, "/v2/verification", body, &out); err != nil {
		return err
	}

	// Logged on every send, not just the failures. Four different statuses all
	// return nil here and they do not all put an SMS on a phone — "challenged"
	// in particular means Prelude chose some other channel — so without this
	// line "the server said it sent a code" and "a text message arrived" are
	// indistinguishable from the outside. That ambiguity cost an afternoon.
	p.logger.Info("prelude verification send",
		zap.String("status", out.Status),
		zap.String("reason", out.Reason),
	)

	switch out.Status {
	case preludeStatusSuccess, preludeStatusRetry, preludeStatusChallenged, preludeStatusShadowBlocked:
		return nil
	case preludeStatusBlocked:
		return classifyPreludeReason(out.Reason)
	default:
		// An unrecognised status is a Prelude change we have not read yet.
		// Failing is the safe direction: pretending a code went out leaves the
		// user waiting for a message that never arrives.
		return fmt.Errorf("prelude verify returned status %q", out.Status)
	}
}

// Check implements Sender.
func (p *PreludeSender) Check(ctx context.Context, e164, code string) (Result, error) {
	body := preludeCheckRequest{
		Target: preludeTarget{Type: "phone_number", Value: e164},
		Code:   code,
	}

	var out preludeResponse
	if err := p.post(ctx, "/v2/verification/check", body, &out); err != nil {
		return ResultDenied, err
	}

	switch out.Status {
	case preludeCheckSuccess:
		return ResultApproved, nil
	case preludeCheckFailure, preludeCheckExpiredOrNotFound:
		// Collapsed on purpose — see the comment on ResultDenied. "Expired"
		// and "wrong" are the same answer to the person typing.
		return ResultDenied, nil
	default:
		// transaction_missing and transaction_mismatch are PSD2-only, and we
		// never issue a PSD2 code. Seeing one means the template changed under
		// us, which should be loud rather than silently denied.
		return ResultDenied, fmt.Errorf("prelude verify check returned status %q", out.Status)
	}
}

// classifyPreludeReason maps a blocked send onto the two conditions a caller can
// act on. The signature reasons are deliberately not mapped: they mean our own
// request was malformed, which is a bug on this side and not something to
// present as "that number can't receive texts".
func classifyPreludeReason(reason string) error {
	switch reason {
	case preludeRepeatedAttempts, preludeRateLimited, preludeTooManyAttempts, preludeTooManyChecks:
		return fmt.Errorf("%w: prelude %s", ErrTooManyAttempts, reason)
	case preludeInvalidPhoneNumber, preludeInvalidPhoneLine, preludeInBlockList, preludeSuspicious:
		return fmt.Errorf("%w: prelude %s", ErrUndeliverable, reason)
	default:
		return fmt.Errorf("prelude verify blocked the request: %s", reason)
	}
}

type preludeAPIError struct {
	Code       string
	HTTPStatus int
	Message    string
}

func (e *preludeAPIError) Error() string {
	return fmt.Sprintf("prelude verify error %q (http %d): %s", e.Code, e.HTTPStatus, e.Message)
}

func (p *PreludeSender) post(ctx context.Context, path string, in, out any) error {
	payload, err := json.Marshal(in)
	if err != nil {
		return fmt.Errorf("encode prelude request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.baseURL+path, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build prelude request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Bearer "+p.apiKey)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("call prelude verify: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	// Bounded read: this is a third party and the body is a small JSON object.
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("read prelude response: %w", err)
	}

	if resp.StatusCode >= 400 {
		var pe preludeErrorBody
		_ = json.Unmarshal(body, &pe)
		// 429 carries the same conditions a blocked 200 does, so it goes
		// through the same mapping rather than a parallel one.
		if resp.StatusCode == http.StatusTooManyRequests {
			return classifyPreludeReason(preludeRateLimitedOr(pe.Code))
		}
		if mapped := classifyPreludeReason(pe.Code); isMappedPreludeError(mapped) {
			return mapped
		}
		return &preludeAPIError{Code: pe.Code, HTTPStatus: resp.StatusCode, Message: pe.Message}
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("decode prelude response: %w", err)
	}
	return nil
}

// preludeRateLimitedOr defaults a 429 with an unreadable body to the rate-limit
// reason, since that is what a 429 means whatever the body says.
func preludeRateLimitedOr(code string) string {
	if strings.TrimSpace(code) == "" {
		return preludeRateLimited
	}
	return code
}

// isMappedPreludeError reports whether classifyPreludeReason recognised the
// code, as opposed to falling through to its generic branch.
func isMappedPreludeError(err error) bool {
	return errors.Is(err, ErrTooManyAttempts) || errors.Is(err, ErrUndeliverable)
}
