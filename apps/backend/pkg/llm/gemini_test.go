package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// serveGemini stands in for the API and hands back whatever the test wants,
// capturing the request so its shape can be asserted.
func serveGemini(t *testing.T, status int, body string) (*GeminiProvider, *geminiRequest, *http.Header) {
	t.Helper()
	var captured geminiRequest
	var headers http.Header

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		headers = r.Header.Clone()
		if r.URL.Path != geminiPath {
			t.Errorf("path = %q, want %q", r.URL.Path, geminiPath)
		}
		_ = json.NewDecoder(r.Body).Decode(&captured)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)

	provider, err := NewGeminiProvider(GeminiOptions{
		APIKey:     "test-key",
		Model:      "gemini-test",
		BaseURL:    server.URL,
		HTTPClient: server.Client(),
	})
	if err != nil {
		t.Fatalf("NewGeminiProvider: %v", err)
	}
	return provider, &captured, &headers
}

const identifyOK = `{
  "model": "gemini-3.6-flash",
  "status": "completed",
  "output_text": "{\"name\":\"IKEA Malm 6-drawer dresser\",\"search_queries\":[\"ikea malm dresser\",\"malm 6 drawer\"],\"key_attributes\":[\"six drawers\",\"white\"],\"listing_title\":\"IKEA Malm 6-Drawer Dresser, White\",\"listing_description\":\"White IKEA Malm dresser with six drawers.\"}",
  "usage": {"total_input_tokens": 1840, "total_output_tokens": 96, "total_thought_tokens": 240, "total_cached_tokens": 12}
}`

func TestIdentifyParsesOutputAndUsage(t *testing.T) {
	provider, request, headers := serveGemini(t, http.StatusOK, identifyOK)

	item, usage, err := provider.Identify(context.Background(), IdentifyInput{
		Description: "white ikea malm dresser",
		Photos:      []Photo{{Data: []byte{0xff, 0xd8, 0xff}, MediaType: "image/jpeg"}},
	})
	if err != nil {
		t.Fatalf("Identify: %v", err)
	}

	if item.Name != "IKEA Malm 6-drawer dresser" {
		t.Errorf("Name = %q", item.Name)
	}
	if len(item.SearchQueries) != 2 {
		t.Errorf("SearchQueries = %v, want 2", item.SearchQueries)
	}

	// The served model, not the configured one — it is what was billed.
	if usage.Model != "gemini-3.6-flash" {
		t.Errorf("usage.Model = %q, want the model the response reported", usage.Model)
	}
	if usage.InputTokens == nil || *usage.InputTokens != 1840 {
		t.Errorf("InputTokens = %v, want 1840", usage.InputTokens)
	}
	// Recorded separately from output, because whether output already includes
	// it is undocumented — see migration 00005.
	if usage.ThoughtTokens == nil || *usage.ThoughtTokens != 240 {
		t.Errorf("ThoughtTokens = %v, want 240", usage.ThoughtTokens)
	}
	if usage.CachedInputTokens == nil || *usage.CachedInputTokens != 12 {
		t.Errorf("CachedInputTokens = %v, want 12", usage.CachedInputTokens)
	}

	// Request shape: the parts array, the key header, and the structured-output
	// block the whole design depends on.
	if headers.Get("x-goog-api-key") != "test-key" {
		t.Errorf("api key header = %q", headers.Get("x-goog-api-key"))
	}
	if request.Model != "gemini-test" {
		t.Errorf("request model = %q, want the configured one", request.Model)
	}
	if len(request.Input) != 2 || request.Input[0].Type != "text" || request.Input[1].Type != "image" {
		t.Fatalf("input parts = %+v, want a text part then an image part", request.Input)
	}
	if request.Input[1].MimeType != "image/jpeg" || len(request.Input[1].Data) != 3 {
		t.Errorf("image part = %+v, want the jpeg bytes and their mime type", request.Input[1])
	}
	if request.ResponseFormat.MimeType != "application/json" || request.ResponseFormat.Schema == nil {
		t.Errorf("response_format = %+v, want a json schema", request.ResponseFormat)
	}
}

// A third query would cost two more page loads against a shared request budget.
func TestIdentifyCapsSearchQueriesAtTwo(t *testing.T) {
	body := `{"status":"completed","output_text":"{\"name\":\"x\",\"search_queries\":[\"a\",\"b\",\"c\",\"d\"]}"}`
	provider, _, _ := serveGemini(t, http.StatusOK, body)

	item, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if err != nil {
		t.Fatalf("Identify: %v", err)
	}
	if len(item.SearchQueries) != 2 {
		t.Errorf("SearchQueries = %v, want capped at 2", item.SearchQueries)
	}
}

// No price is ever asked for or parsed here, and this is the test that says so.
// The prompt used to carry a page of figures; if one ever comes back, somebody
// has reintroduced the call whose arithmetic this feature does not trust.
func TestIdentifyPromptCarriesNoMarketNumbers(t *testing.T) {
	provider, request, _ := serveGemini(t, http.StatusOK, identifyOK)

	if _, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "a dresser"}); err != nil {
		t.Fatalf("Identify: %v", err)
	}
	prompt := request.Input[0].Text
	for _, forbidden := range []string{"median", "lowest", "highest", "asking"} {
		if strings.Contains(strings.ToLower(prompt), forbidden) {
			t.Errorf("prompt mentions %q — the model must not see the market", forbidden)
		}
	}
}

// A 200 whose status is not "completed" is a truncated or refused answer, and
// treating it as good is how a half-written listing reaches somebody.
func TestNonCompletedStatusIsAnError(t *testing.T) {
	body := `{"status":"incomplete","output_text":"{\"name\":\"x\",\"search_queries\":[\"y\"]}","usage":{"total_input_tokens":40}}`
	provider, _, _ := serveGemini(t, http.StatusOK, body)

	_, usage, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if CodeOf(err) != ErrorCodeInvalidOutput {
		t.Errorf("code = %v, want invalid_output", CodeOf(err))
	}
	// The call still cost tokens, and the row has to say so.
	if usage.InputTokens == nil || *usage.InputTokens != 40 {
		t.Errorf("InputTokens = %v, want the reported 40 even on failure", usage.InputTokens)
	}
}

func TestHTTPStatusesMapToCodes(t *testing.T) {
	cases := []struct {
		status int
		want   ErrorCode
	}{
		{http.StatusTooManyRequests, ErrorCodeRateLimited},
		// See the note in gateway_test.go: a 400 is ours, not the model's.
		{http.StatusBadRequest, ErrorCodeBadRequest},
		{http.StatusForbidden, ErrorCodeBadRequest},
		{http.StatusInternalServerError, ErrorCodeUnavailable},
		{http.StatusServiceUnavailable, ErrorCodeUnavailable},
	}
	for _, tc := range cases {
		provider, _, _ := serveGemini(t, tc.status, `{"error":{"code":"x","message":"nope"}}`)
		_, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
		if got := CodeOf(err); got != tc.want {
			t.Errorf("http %d -> %v, want %v", tc.status, got, tc.want)
		}
	}
}

// Output that is not the requested shape is retryable — a reroll usually fixes
// it — so it must classify as invalid_output rather than unknown.
func TestMalformedOutputTextIsInvalidOutput(t *testing.T) {
	provider, _, _ := serveGemini(t, http.StatusOK, `{"status":"completed","output_text":"not json at all"}`)

	_, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if CodeOf(err) != ErrorCodeInvalidOutput {
		t.Errorf("code = %v, want invalid_output", CodeOf(err))
	}
}

func TestIdentifyRejectsEmptyIdentification(t *testing.T) {
	provider, _, _ := serveGemini(t, http.StatusOK, `{"status":"completed","output_text":"{\"name\":\"\",\"search_queries\":[]}"}`)

	_, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if CodeOf(err) != ErrorCodeInvalidOutput {
		t.Errorf("code = %v, want invalid_output", CodeOf(err))
	}
}

func TestNewGeminiProviderRequiresKeyAndModel(t *testing.T) {
	if _, err := NewGeminiProvider(GeminiOptions{Model: "m"}); err == nil {
		t.Error("want an error with no api key")
	}
	if _, err := NewGeminiProvider(GeminiOptions{APIKey: "k"}); err == nil {
		t.Error("want an error with no model")
	}
}

// TestComparableLineMarksSoldAndFree stood here. It pinned down how a listing
// was rendered into the pricing prompt — free items as "free", sold ones with
// the days they sat — and it went with the prompt. No comparable is rendered
// for a model any more; they are counted, and the counting is Swift's.
