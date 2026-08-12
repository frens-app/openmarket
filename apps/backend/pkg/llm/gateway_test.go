package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func serveGateway(t *testing.T, status int, body string) (*GatewayProvider, *gatewayRequest, *http.Header) {
	t.Helper()
	var captured gatewayRequest
	var headers http.Header

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		headers = r.Header.Clone()
		if r.URL.Path != "/v1"+gatewayPath {
			t.Errorf("path = %q, want %q", r.URL.Path, "/v1"+gatewayPath)
		}
		_ = json.NewDecoder(r.Body).Decode(&captured)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)

	provider, err := NewGatewayProvider(GatewayOptions{
		APIKey:     "test-key",
		Model:      "google/gemini-test",
		BaseURL:    server.URL + "/v1",
		HTTPClient: server.Client(),
	})
	if err != nil {
		t.Fatalf("NewGatewayProvider: %v", err)
	}
	return provider, &captured, &headers
}

const gatewayIdentifyOK = `{
  "model": "google/gemini-3.6-flash",
  "choices": [{
    "message": {"role":"assistant","content":"{\"name\":\"IKEA Malm 6-drawer dresser\",\"search_queries\":[\"ikea malm dresser\"],\"key_attributes\":[\"six drawers\"],\"listing_title\":\"IKEA Malm 6-Drawer Dresser, White\",\"listing_description\":\"White IKEA Malm dresser with six drawers.\"}"},
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 1840,
    "completion_tokens": 96,
    "total_tokens": 1936,
    "completion_tokens_details": {"reasoning_tokens": 240},
    "prompt_tokens_details": {"cached_tokens": 12}
  }
}`

func TestGatewayIdentifyParsesOutputAndUsage(t *testing.T) {
	provider, request, headers := serveGateway(t, http.StatusOK, gatewayIdentifyOK)

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

	// The usage field names are the entire reason this file exists — they share
	// nothing with Google's native shape.
	if usage.InputTokens == nil || *usage.InputTokens != 1840 {
		t.Errorf("InputTokens = %v, want 1840 from prompt_tokens", usage.InputTokens)
	}
	if usage.OutputTokens == nil || *usage.OutputTokens != 96 {
		t.Errorf("OutputTokens = %v, want 96 from completion_tokens", usage.OutputTokens)
	}
	if usage.ThoughtTokens == nil || *usage.ThoughtTokens != 240 {
		t.Errorf("ThoughtTokens = %v, want 240 from completion_tokens_details", usage.ThoughtTokens)
	}
	if usage.CachedInputTokens == nil || *usage.CachedInputTokens != 12 {
		t.Errorf("CachedInputTokens = %v, want 12 from prompt_tokens_details", usage.CachedInputTokens)
	}
	if usage.Model != "google/gemini-3.6-flash" {
		t.Errorf("usage.Model = %q, want the served model", usage.Model)
	}

	if headers.Get("Authorization") != "Bearer test-key" {
		t.Errorf("Authorization = %q", headers.Get("Authorization"))
	}
	if request.Stream {
		t.Error("stream = true, want false — nothing here consumes a stream")
	}
	if request.ResponseFormat.Type != "json_schema" || request.ResponseFormat.JSONSchema.Schema == nil {
		t.Errorf("response_format = %+v, want a named json_schema", request.ResponseFormat)
	}
	if request.ResponseFormat.JSONSchema.Name == "" {
		t.Error("json_schema.name is required by this surface and was empty")
	}
}

// Inline bytes ride in a data URL here, not as separate data + mime_type fields.
func TestGatewaySendsImageAsDataURL(t *testing.T) {
	provider, request, _ := serveGateway(t, http.StatusOK, gatewayIdentifyOK)

	_, _, err := provider.Identify(context.Background(), IdentifyInput{
		Description: "x",
		Photos:      []Photo{{Data: []byte{0x01, 0x02}, MediaType: "image/jpeg"}},
	})
	if err != nil {
		t.Fatalf("Identify: %v", err)
	}

	content := request.Messages[0].Content
	if len(content) != 2 || content[1].Type != "image_url" || content[1].ImageURL == nil {
		t.Fatalf("content = %+v, want a text part then an image_url part", content)
	}
	if !strings.HasPrefix(content[1].ImageURL.URL, "data:image/jpeg;base64,") {
		t.Errorf("image url = %q, want a jpeg data URL", content[1].ImageURL.URL)
	}
}

// The listing rides back on the same call as the identification, so a response
// that carries one and not the other has to be caught here rather than looking
// like an empty listing on somebody's screen.
func TestGatewayIdentifyReturnsTheListing(t *testing.T) {
	provider, _, _ := serveGateway(t, http.StatusOK, gatewayIdentifyOK)

	item, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "ikea malm dresser"})
	if err != nil {
		t.Fatalf("Identify: %v", err)
	}
	if item.ListingTitle != "IKEA Malm 6-Drawer Dresser, White" {
		t.Errorf("ListingTitle = %q", item.ListingTitle)
	}
	if !strings.Contains(item.ListingBody, "six drawers") {
		t.Errorf("ListingBody = %q", item.ListingBody)
	}
}

// Copy is not load-bearing: the price is arithmetic and never touched it, so a
// response with a name and a query but no listing is a worse result, not a
// failed run.
func TestGatewayIdentifySurvivesMissingCopy(t *testing.T) {
	body := `{"choices":[{"message":{"content":"{\"name\":\"Dresser\",\"search_queries\":[\"dresser\"]}"},"finish_reason":"stop"}]}`
	provider, _, _ := serveGateway(t, http.StatusOK, body)

	item, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "a dresser"})
	if err != nil {
		t.Fatalf("Identify should not fail without copy: %v", err)
	}
	if item.Name != "Dresser" || item.ListingTitle != "" {
		t.Errorf("item = %+v", item)
	}
}

// Truncated JSON that happens to parse is worse than an error, so length is
// caught before the content is looked at.
func TestGatewayTruncatedOutputIsInvalidOutput(t *testing.T) {
	body := `{"choices":[{"message":{"content":"{\"name\":\"x\",\"search_queries\":[\"y\"]}"},"finish_reason":"length"}],"usage":{"prompt_tokens":40}}`
	provider, _, _ := serveGateway(t, http.StatusOK, body)

	_, usage, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if CodeOf(err) != ErrorCodeInvalidOutput {
		t.Errorf("code = %v, want invalid_output", CodeOf(err))
	}
	if usage.InputTokens == nil || *usage.InputTokens != 40 {
		t.Errorf("InputTokens = %v, want the reported 40 even on failure", usage.InputTokens)
	}
}

// A content filter is a decision about the input; retrying spends money to be
// told no twice.
func TestGatewayContentFilterIsRefused(t *testing.T) {
	body := `{"choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}`
	provider, _, _ := serveGateway(t, http.StatusOK, body)

	_, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if CodeOf(err) != ErrorCodeRefused {
		t.Errorf("code = %v, want refused", CodeOf(err))
	}
}

func TestGatewayHTTPStatusesMapToCodes(t *testing.T) {
	cases := []struct {
		status int
		want   ErrorCode
	}{
		{http.StatusTooManyRequests, ErrorCodeRateLimited},
		// bad_request, not refused: a 400 is our request being wrong, and the
		// two must stay distinguishable because only one of them is worth
		// telling the user to reword their item over.
		{http.StatusBadRequest, ErrorCodeBadRequest},
		{http.StatusUnauthorized, ErrorCodeBadRequest},
		{http.StatusInternalServerError, ErrorCodeUnavailable},
	}
	for _, tc := range cases {
		provider, _, _ := serveGateway(t, tc.status, `{"error":{"message":"nope","type":"invalid_request_error"}}`)
		_, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
		if got := CodeOf(err); got != tc.want {
			t.Errorf("http %d -> %v, want %v", tc.status, got, tc.want)
		}
	}
}

func TestGatewayNoChoicesIsInvalidOutput(t *testing.T) {
	provider, _, _ := serveGateway(t, http.StatusOK, `{"choices":[]}`)

	_, _, err := provider.Identify(context.Background(), IdentifyInput{Description: "x"})
	if CodeOf(err) != ErrorCodeInvalidOutput {
		t.Errorf("code = %v, want invalid_output", CodeOf(err))
	}
}

// An unprefixed model id is a 404 on the first real request, so it is refused
// at construction where the message can say what to do about it.
func TestGatewayRequiresProviderPrefixedModel(t *testing.T) {
	_, err := NewGatewayProvider(GatewayOptions{APIKey: "k", Model: "gemini-3.6-flash"})
	if err == nil {
		t.Fatal("want an error for an unprefixed model id")
	}
	if !strings.Contains(err.Error(), "google/gemini-3.6-flash") {
		t.Errorf("error should suggest the prefixed form, got: %v", err)
	}

	if _, err := NewGatewayProvider(GatewayOptions{APIKey: "k", Model: "google/gemini-3.6-flash"}); err != nil {
		t.Errorf("prefixed model rejected: %v", err)
	}
}

func TestGatewayRequiresKey(t *testing.T) {
	if _, err := NewGatewayProvider(GatewayOptions{Model: "google/x"}); err == nil {
		t.Error("want an error with no api key")
	}
}
