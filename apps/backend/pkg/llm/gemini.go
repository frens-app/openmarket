package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// GeminiProvider talks to Google's Interactions API.
//
// Raw HTTP and no SDK, for the same reason `verify.PreludeSender` is: this is
// two JSON POSTs against one endpoint, and the official Go module covers every
// product Google sells in order to save about eighty lines. The shapes below
// were read off the API reference rather than remembered.
//
// Two things about that shape are worth knowing before changing anything:
//
//   - **The endpoint is `/v1beta/interactions`, not `generateContent`.** Input
//     is a flat array of typed parts, structured output is `response_format`
//     rather than a `generationConfig`, and the answer comes back on
//     `output_text`. Code written against the older `generateContent` shape
//     does not work here and fails as a 400.
//   - **A refused or truncated call can still be HTTP 200.** `status` carries
//     the completion state, so a response is only usable when that says
//     `completed` — checking the status code alone would treat a truncated
//     answer as a good one.
const (
	defaultGeminiBaseURL = "https://generativelanguage.googleapis.com"
	geminiPath           = "/v1beta/interactions"
)

// Completion states on the response. Anything other than completed means the
// output is absent or partial.
const (
	geminiStatusCompleted      = "completed"
	geminiStatusFailed         = "failed"
	geminiStatusCancelled      = "cancelled"
	geminiStatusIncomplete     = "incomplete"
	geminiStatusBudgetExceeded = "budget_exceeded"
)

type GeminiProvider struct {
	apiKey     string
	model      string
	baseURL    string
	httpClient *http.Client
}

// GeminiOptions configures the provider.
type GeminiOptions struct {
	APIKey string
	// Model is the id sent on every request, e.g. "gemini-3.6-flash". Config
	// requires it rather than defaulting it: a model id is the thing that
	// decides both the bill and the answer, so it belongs somewhere visible and
	// deployable rather than compiled in.
	Model string
	// BaseURL is for tests only — it is deliberately not wired to any
	// configuration value, so a running service cannot be pointed at something
	// that isn't Google. Same reasoning as PreludeOptions.BaseURL.
	BaseURL    string
	HTTPClient *http.Client
}

func NewGeminiProvider(opts GeminiOptions) (*GeminiProvider, error) {
	if strings.TrimSpace(opts.APIKey) == "" {
		return nil, fmt.Errorf("gemini: api key is required")
	}
	if strings.TrimSpace(opts.Model) == "" {
		return nil, fmt.Errorf("gemini: model is required")
	}
	client := opts.HTTPClient
	if client == nil {
		// No timeout here: the runner gives every attempt a context deadline,
		// and two competing timeouts means the shorter one silently wins and
		// the configured one is a lie.
		client = &http.Client{}
	}
	baseURL := opts.BaseURL
	if baseURL == "" {
		baseURL = defaultGeminiBaseURL
	}
	return &GeminiProvider{
		apiKey:     opts.APIKey,
		model:      opts.Model,
		baseURL:    strings.TrimSuffix(baseURL, "/"),
		httpClient: client,
	}, nil
}

func (*GeminiProvider) Name() string { return "google" }

// MARK: - Identify

func (g *GeminiProvider) Identify(ctx context.Context, in IdentifyInput) (IdentifiedItem, Usage, error) {
	parts := []geminiPart{{Type: "text", Text: identifyPrompt(in.Description)}}
	for _, photo := range in.Photos {
		parts = append(parts, geminiPart{
			Type:     "image",
			Data:     photo.Data,
			MimeType: photo.MediaType,
		})
	}

	var out struct {
		Name          string   `json:"name"`
		SearchQueries []string `json:"search_queries"`
		Condition     string   `json:"condition"`
		KeyAttributes []string `json:"key_attributes"`
	}
	usage, err := g.call(ctx, parts, identifySchema, &out)
	if err != nil {
		return IdentifiedItem{}, usage, err
	}
	if strings.TrimSpace(out.Name) == "" || len(out.SearchQueries) == 0 {
		return IdentifiedItem{}, usage, Errorf(ErrorCodeInvalidOutput,
			"gemini: identification came back without a name or a query")
	}
	// Two is the cap the caller can afford: each query costs up to two page
	// loads, and the request pacer is shared with the browse tab.
	if len(out.SearchQueries) > 2 {
		out.SearchQueries = out.SearchQueries[:2]
	}
	return IdentifiedItem{
		Name:          out.Name,
		SearchQueries: out.SearchQueries,
		Condition:     out.Condition,
		KeyAttributes: out.KeyAttributes,
	}, usage, nil
}

// MARK: - Price

func (g *GeminiProvider) Price(ctx context.Context, in PriceInput) (PricedItem, Usage, error) {
	parts := []geminiPart{{Type: "text", Text: pricePrompt(in)}}

	// **Whole units, converted here.** The wire and the database are both minor
	// units, and asking the model for minor units would invite the single worst
	// bug this feature can have: a hundredfold error in a price, printed under
	// the one figure a person acts on. Every number in the prompt is written the
	// way the cards are written, the model answers in those same units, and the
	// ×100 happens in Go where it cannot be reasoned about incorrectly.
	var out struct {
		Price int64  `json:"price"`
		Title string `json:"title"`
		Body  string `json:"description"`
	}
	usage, err := g.call(ctx, parts, priceSchema, &out)
	if err != nil {
		return PricedItem{}, usage, err
	}
	if out.Price <= 0 || strings.TrimSpace(out.Title) == "" {
		return PricedItem{}, usage, Errorf(ErrorCodeInvalidOutput,
			"gemini: pricing came back without a price or a title")
	}
	return PricedItem{PriceMinor: out.Price * 100, Title: out.Title, Body: out.Body}, usage, nil
}

// MARK: - Wire

type geminiPart struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
	// Base64 on the wire — `encoding/json` does that for []byte, so the bytes
	// are handed over raw here rather than pre-encoded.
	Data     []byte `json:"data,omitempty"`
	MimeType string `json:"mime_type,omitempty"`
}

type geminiRequest struct {
	Model          string               `json:"model"`
	Input          []geminiPart         `json:"input"`
	ResponseFormat geminiResponseFormat `json:"response_format"`
}

type geminiResponseFormat struct {
	Type     string         `json:"type"`
	MimeType string         `json:"mime_type"`
	Schema   map[string]any `json:"schema"`
}

type geminiResponse struct {
	Model      string `json:"model"`
	Status     string `json:"status"`
	OutputText string `json:"output_text"`
	Usage      struct {
		TotalInputTokens   int32 `json:"total_input_tokens"`
		TotalOutputTokens  int32 `json:"total_output_tokens"`
		TotalThoughtTokens int32 `json:"total_thought_tokens"`
		TotalCachedTokens  int32 `json:"total_cached_tokens"`
	} `json:"usage"`
	Error *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// call posts one interaction and decodes its JSON output into `out`.
//
// Usage is returned even on failure wherever the provider reported it: a call
// that produced tokens and then returned something unusable still cost money,
// and a run row with no counts on it would under-report the bill.
func (g *GeminiProvider) call(ctx context.Context, parts []geminiPart, schema map[string]any, out any) (Usage, error) {
	body, err := json.Marshal(geminiRequest{
		Model: g.model,
		Input: parts,
		ResponseFormat: geminiResponseFormat{
			Type:     "text",
			MimeType: "application/json",
			Schema:   schema,
		},
	})
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnknown, "gemini: encode request: %v", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.baseURL+geminiPath, bytes.NewReader(body))
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnknown, "gemini: build request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-goog-api-key", g.apiKey)

	resp, err := g.httpClient.Do(req)
	if err != nil {
		// The runner reclassifies this as a timeout when the deadline is what
		// fired; everything else that stops a request in flight is transient.
		return Usage{Model: g.model}, Errorf(ErrorCodeUnavailable, "gemini: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	// Capped: an error body from a proxy rather than the API can be a whole
	// HTML page, and none of it belongs in a log line.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnavailable, "gemini: read response: %v", err)
	}

	var decoded geminiResponse
	// Deliberately tolerant: a non-2xx body might not be the documented shape
	// at all, and the status code is the more reliable signal there.
	_ = json.Unmarshal(raw, &decoded)
	usage := geminiUsage(decoded, g.model)

	if resp.StatusCode != http.StatusOK {
		return usage, Errorf(statusErrorCode(resp.StatusCode), "gemini: http %d: %s",
			resp.StatusCode, geminiMessage(decoded, raw))
	}
	if decoded.Status != "" && decoded.Status != geminiStatusCompleted {
		return usage, Errorf(completionErrorCode(decoded.Status), "gemini: status %q: %s",
			decoded.Status, geminiMessage(decoded, raw))
	}
	if strings.TrimSpace(decoded.OutputText) == "" {
		return usage, Errorf(ErrorCodeInvalidOutput, "gemini: no output text")
	}
	if err := json.Unmarshal([]byte(decoded.OutputText), out); err != nil {
		// Retryable, and usually a reroll away from being fine — which is why
		// invalid_output is on the runner's retry list.
		return usage, Errorf(ErrorCodeInvalidOutput, "gemini: output was not the requested shape: %v", err)
	}
	return usage, nil
}

func geminiUsage(resp geminiResponse, fallbackModel string) Usage {
	model := resp.Model
	if model == "" {
		// The served model is preferred because it is what was billed; ours is
		// the next best thing, and better than an empty column.
		model = fallbackModel
	}
	usage := Usage{Model: model}
	// Zero and absent are the same on the wire here, so a reported zero is
	// treated as absent rather than asserted as a measurement.
	if resp.Usage.TotalInputTokens > 0 {
		usage.InputTokens = &resp.Usage.TotalInputTokens
	}
	if resp.Usage.TotalOutputTokens > 0 {
		usage.OutputTokens = &resp.Usage.TotalOutputTokens
	}
	if resp.Usage.TotalThoughtTokens > 0 {
		usage.ThoughtTokens = &resp.Usage.TotalThoughtTokens
	}
	if resp.Usage.TotalCachedTokens > 0 {
		usage.CachedInputTokens = &resp.Usage.TotalCachedTokens
	}
	return usage
}

func geminiMessage(resp geminiResponse, raw []byte) string {
	if resp.Error != nil && resp.Error.Message != "" {
		return resp.Error.Message
	}
	const limit = 300
	text := strings.TrimSpace(string(raw))
	if len(text) > limit {
		return text[:limit] + "…"
	}
	return text
}

func statusErrorCode(status int) ErrorCode {
	switch {
	case status == http.StatusTooManyRequests:
		return ErrorCodeRateLimited
	case status == http.StatusBadRequest:
		// Ours, not theirs. Not `refused`: the model never saw this, so telling
		// the user to reword their item would be advice about somebody else's
		// bug. See ErrorCodeBadRequest for the one that made the difference
		// concrete.
		return ErrorCodeBadRequest
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		// A key problem, and equally not the user's item.
		return ErrorCodeBadRequest
	case status >= 500:
		return ErrorCodeUnavailable
	default:
		return ErrorCodeUnknown
	}
}

func completionErrorCode(status string) ErrorCode {
	switch status {
	case geminiStatusFailed, geminiStatusCancelled:
		return ErrorCodeUnavailable
	case geminiStatusIncomplete, geminiStatusBudgetExceeded:
		// Output was cut short. A retry can produce a whole answer, so this is
		// treated as transient rather than as a refusal.
		return ErrorCodeInvalidOutput
	default:
		return ErrorCodeUnknown
	}
}
