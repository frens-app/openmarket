package llm

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// GatewayProvider talks to Vercel's AI Gateway over its OpenAI Chat Completions
// surface.
//
// The Gateway offers three shapes — Chat Completions, OpenAI Responses, and
// Anthropic Messages — and this is the Chat Completions one, because the reason
// to route through a gateway at all is to change models without changing code.
// That shape is the one every model behind it maps onto; the other two are each
// native to a single vendor and translated for everyone else, so they are the
// ones with edges when pointed somewhere unexpected.
//
// It carries both things this package needs: `response_format` with a JSON
// Schema, and a usage object that reports reasoning tokens separately.
//
// **One known gap, and it is not one we hit.** The Chat Completions `reasoning`
// object does not reach Anthropic's `output_config` on Claude Opus 4.7 and
// later, so on those models `effort` returns no reasoning tokens and
// `max_tokens` is rejected outright. Nothing here sets `reasoning` — the depth
// of the model's thinking is its own business, and all this wants is the answer
// and the counts. If configuring extended thinking on a recent Claude ever
// becomes the point, that is the reason to add an Anthropic Messages provider
// beside this one rather than to bend this one.
const (
	defaultGatewayBaseURL = "https://ai-gateway.vercel.sh/v1"
	gatewayPath           = "/chat/completions"
)

// Reasons a completion stopped. Anything but "stop" means the content is
// partial or absent.
const (
	gatewayFinishStop   = "stop"
	gatewayFinishLength = "length"
)

type GatewayProvider struct {
	apiKey     string
	model      string
	baseURL    string
	httpClient *http.Client
}

// GatewayOptions configures the provider.
type GatewayOptions struct {
	APIKey string
	// Model is provider-prefixed — "google/gemini-3.6-flash",
	// "anthropic/claude-opus-5", "openai/gpt-5.6-sol". The prefix is not
	// decoration: an unprefixed id is not a model the Gateway knows, and the
	// constructor refuses one rather than letting it become a 404 on the first
	// real request.
	Model string
	// BaseURL is for tests only, and deliberately not wired to configuration —
	// same reasoning as PreludeOptions.BaseURL and GeminiOptions.BaseURL.
	BaseURL    string
	HTTPClient *http.Client
}

func NewGatewayProvider(opts GatewayOptions) (*GatewayProvider, error) {
	if strings.TrimSpace(opts.APIKey) == "" {
		return nil, fmt.Errorf("gateway: api key is required")
	}
	model := strings.TrimSpace(opts.Model)
	if model == "" {
		return nil, fmt.Errorf("gateway: model is required")
	}
	if !strings.Contains(model, "/") {
		return nil, fmt.Errorf(
			"gateway: model %q needs a provider prefix, e.g. %q — the Gateway routes on it",
			model, "google/"+model)
	}
	client := opts.HTTPClient
	if client == nil {
		// Deadlines come from the runner's per-attempt context; a second
		// timeout here would silently win whenever it was shorter.
		client = &http.Client{}
	}
	baseURL := opts.BaseURL
	if baseURL == "" {
		baseURL = defaultGatewayBaseURL
	}
	return &GatewayProvider{
		apiKey:     opts.APIKey,
		model:      model,
		baseURL:    strings.TrimSuffix(baseURL, "/"),
		httpClient: client,
	}, nil
}

// Name is the route, not the vendor. Which vendor actually served it is in the
// model string beside it — "vercel" + "google/gemini-3.6-flash" says both
// things, where flattening them into one column would lose whichever mattered.
func (*GatewayProvider) Name() string { return "vercel" }

func (g *GatewayProvider) Identify(ctx context.Context, in IdentifyInput) (IdentifiedItem, Usage, error) {
	parts := []gatewayPart{{Type: "text", Text: identifyPrompt(in.Description)}}
	for _, photo := range in.Photos {
		parts = append(parts, gatewayPart{
			Type: "image_url",
			// A data URL, which is how this surface carries inline bytes —
			// unlike Google's native API, which takes the base64 and the mime
			// type as separate fields.
			ImageURL: &gatewayImageURL{URL: dataURL(photo)},
		})
	}

	var out struct {
		Name          string   `json:"name"`
		SearchQueries []string `json:"search_queries"`
		KeyAttributes []string `json:"key_attributes"`
		ListingTitle  string   `json:"listing_title"`
		ListingBody   string   `json:"listing_description"`
	}
	usage, err := g.call(ctx, parts, "item_identification", identifySchema, &out)
	if err != nil {
		return IdentifiedItem{}, usage, err
	}
	// Only the name and the query are load-bearing: without them there is
	// nothing to search and the run is over. Missing copy is a worse listing,
	// not a dead run, so it is not checked here.
	if strings.TrimSpace(out.Name) == "" || len(out.SearchQueries) == 0 {
		return IdentifiedItem{}, usage, Errorf(ErrorCodeInvalidOutput,
			"gateway: identification came back without a name or a query")
	}
	if len(out.SearchQueries) > 2 {
		out.SearchQueries = out.SearchQueries[:2]
	}
	return IdentifiedItem{
		Name:          out.Name,
		SearchQueries: out.SearchQueries,
		KeyAttributes: out.KeyAttributes,
		ListingTitle:  out.ListingTitle,
		ListingBody:   out.ListingBody,
	}, usage, nil
}

// MARK: - Wire

type gatewayImageURL struct {
	URL string `json:"url"`
}

type gatewayPart struct {
	Type     string           `json:"type"`
	Text     string           `json:"text,omitempty"`
	ImageURL *gatewayImageURL `json:"image_url,omitempty"`
}

type gatewayMessage struct {
	Role    string        `json:"role"`
	Content []gatewayPart `json:"content"`
}

type gatewayRequest struct {
	Model          string                `json:"model"`
	Messages       []gatewayMessage      `json:"messages"`
	Stream         bool                  `json:"stream"`
	ResponseFormat gatewayResponseFormat `json:"response_format"`
}

type gatewayResponseFormat struct {
	Type       string            `json:"type"`
	JSONSchema gatewayJSONSchema `json:"json_schema"`
}

type gatewayJSONSchema struct {
	Name   string         `json:"name"`
	Schema map[string]any `json:"schema"`
}

type gatewayResponse struct {
	Model   string `json:"model"`
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int32 `json:"prompt_tokens"`
		CompletionTokens int32 `json:"completion_tokens"`
		// Reasoning is nested here rather than being a top-level counter, and
		// it is the field that fills the thought_tokens column.
		CompletionTokensDetails struct {
			ReasoningTokens int32 `json:"reasoning_tokens"`
		} `json:"completion_tokens_details"`
		PromptTokensDetails struct {
			CachedTokens int32 `json:"cached_tokens"`
		} `json:"prompt_tokens_details"`
	} `json:"usage"`
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
		Code    string `json:"code"`
	} `json:"error"`
}

func (g *GatewayProvider) call(
	ctx context.Context,
	parts []gatewayPart,
	schemaName string,
	schema map[string]any,
	out any,
) (Usage, error) {
	body, err := json.Marshal(gatewayRequest{
		Model:    g.model,
		Messages: []gatewayMessage{{Role: "user", Content: parts}},
		Stream:   false,
		ResponseFormat: gatewayResponseFormat{
			Type:       "json_schema",
			JSONSchema: gatewayJSONSchema{Name: schemaName, Schema: schema},
		},
	})
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnknown, "gateway: encode request: %v", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.baseURL+gatewayPath, bytes.NewReader(body))
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnknown, "gateway: build request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+g.apiKey)

	resp, err := g.httpClient.Do(req)
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnavailable, "gateway: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Usage{Model: g.model}, Errorf(ErrorCodeUnavailable, "gateway: read response: %v", err)
	}

	var decoded gatewayResponse
	_ = json.Unmarshal(raw, &decoded)
	usage := gatewayUsage(decoded, g.model)

	if resp.StatusCode != http.StatusOK {
		return usage, Errorf(statusErrorCode(resp.StatusCode), "gateway: http %d: %s",
			resp.StatusCode, gatewayMessageText(decoded, raw))
	}
	if len(decoded.Choices) == 0 {
		return usage, Errorf(ErrorCodeInvalidOutput, "gateway: no choices in response")
	}
	choice := decoded.Choices[0]
	// "length" means the answer was cut off mid-JSON. Retryable, and it must
	// not be parsed — half a listing that happens to close its braces is worse
	// than an error.
	if choice.FinishReason == gatewayFinishLength {
		return usage, Errorf(ErrorCodeInvalidOutput, "gateway: output truncated at the token limit")
	}
	if choice.FinishReason != "" && choice.FinishReason != gatewayFinishStop {
		// Content filters and provider-side refusals land here. Not retryable:
		// the same input gets the same answer.
		return usage, Errorf(ErrorCodeRefused, "gateway: finish_reason %q", choice.FinishReason)
	}
	if strings.TrimSpace(choice.Message.Content) == "" {
		return usage, Errorf(ErrorCodeInvalidOutput, "gateway: empty content")
	}
	if err := json.Unmarshal([]byte(choice.Message.Content), out); err != nil {
		return usage, Errorf(ErrorCodeInvalidOutput, "gateway: output was not the requested shape: %v", err)
	}
	return usage, nil
}

// dataURL renders a photo the way this surface takes inline bytes.
func dataURL(photo Photo) string {
	mediaType := photo.MediaType
	if mediaType == "" {
		mediaType = "image/jpeg"
	}
	return "data:" + mediaType + ";base64," + base64.StdEncoding.EncodeToString(photo.Data)
}

func gatewayUsage(resp gatewayResponse, fallbackModel string) Usage {
	model := resp.Model
	if model == "" {
		model = fallbackModel
	}
	usage := Usage{Model: model}
	if resp.Usage.PromptTokens > 0 {
		usage.InputTokens = &resp.Usage.PromptTokens
	}
	if resp.Usage.CompletionTokens > 0 {
		usage.OutputTokens = &resp.Usage.CompletionTokens
	}
	if resp.Usage.CompletionTokensDetails.ReasoningTokens > 0 {
		usage.ThoughtTokens = &resp.Usage.CompletionTokensDetails.ReasoningTokens
	}
	if resp.Usage.PromptTokensDetails.CachedTokens > 0 {
		usage.CachedInputTokens = &resp.Usage.PromptTokensDetails.CachedTokens
	}
	return usage
}

func gatewayMessageText(resp gatewayResponse, raw []byte) string {
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
