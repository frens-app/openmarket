package llm

import (
	"encoding/json"
	"strings"
	"testing"
)

// The schema is sent to a provider verbatim, so a construct that is legal JSON
// Schema but illegal to the provider is a 400 on every call — not a bad answer
// on some of them. A fake HTTP server will never catch that, because a fake
// accepts whatever it is handed. These tests stand in for the checks the
// provider does, and each one is here because it was seen failing against the
// real thing.

// Vertex rejects the whole request with
//
//	response_schema.properties[condition].enum[0]: cannot be empty
//
// The `condition` field it names is gone, but the rule it taught is not: an
// empty string is never a legal enum member, and "unknown" has to be spelled by
// omitting the field. Kept as a standing check on whatever enum comes next.
func TestSchemaHasNoEmptyEnumMembers(t *testing.T) {
	props, _ := identifySchema["properties"].(map[string]any)
	for field, raw := range props {
		spec, _ := raw.(map[string]any)
		values, ok := spec["enum"].([]string)
		if !ok {
			continue
		}
		for i, v := range values {
			if strings.TrimSpace(v) == "" {
				t.Errorf("identify schema: %s.enum[%d] is empty; omit the field instead", field, i)
			}
		}
	}
}

// The schema crosses the wire as JSON. A map that cannot be marshalled fails at
// the request, after the photo has already been uploaded and the user is
// waiting.
func TestSchemaMarshals(t *testing.T) {
	if _, err := json.Marshal(identifySchema); err != nil {
		t.Errorf("identify schema does not marshal: %v", err)
	}
}

// The listing is required output now, not a second call's job. If it drops out
// of `required` the model is free to answer without it, and the run produces a
// price with no words to go beside it.
func TestSchemaRequiresTheListing(t *testing.T) {
	required, _ := identifySchema["required"].([]string)
	for _, want := range []string{"name", "search_queries", "listing_title", "listing_description"} {
		var found bool
		for _, field := range required {
			if field == want {
				found = true
			}
		}
		if !found {
			t.Errorf("%q is not required", want)
		}
	}
}

// A photo-only run must not produce a prompt that ends "The seller's
// description:" with nothing after it — that reads as a quoted silence, and a
// model asked to work from a blank quotation fills it in.
func TestPromptWithNoDescriptionSaysThereIsNone(t *testing.T) {
	prompt := identifyPrompt("   ")
	if strings.Contains(prompt, "The seller's description:") {
		t.Error("photo-only prompt still quotes a description that does not exist")
	}
	if !strings.Contains(prompt, "a photo and nothing else") {
		t.Error("photo-only prompt should say the photo is all there is")
	}
	if !strings.Contains(prompt, "no seller description at all") {
		t.Error("photo-only prompt should constrain the listing to what is visible")
	}
}

func TestPromptWithADescriptionQuotesIt(t *testing.T) {
	prompt := identifyPrompt("white bookshelf, one shelf cracked")
	if !strings.Contains(prompt, "The seller's description:\nwhite bookshelf, one shelf cracked") {
		t.Error("the seller's words are missing from the prompt")
	}
	if strings.Contains(prompt, "no seller description at all") {
		t.Error("the photo-only rule leaked into a run that had a description")
	}
}

// The whole point of one call is that the model never sees the market. If a
// figure ever appears in this prompt, the failure it was removed to prevent —
// arithmetic about a sample it was just shown — is reachable again.
func TestPromptNeverCarriesMarketNumbers(t *testing.T) {
	for _, description := range []string{"", "a dresser, $80 on Craigslist"} {
		prompt := strings.ToLower(identifyPrompt(description))
		// Only the instruction sentence may mention prices, and only to forbid
		// them. Everything else would be a figure.
		if strings.Contains(prompt, "median") || strings.Contains(prompt, "comparable listings are asking") {
			t.Errorf("prompt carries market figures for description %q", description)
		}
	}
}

// The listing rules are the ones with a measured failure behind them: a small
// model asked for richer prose wrote "a few minor scratches on the frame" about
// a bike whose seller mentioned none.
func TestPromptForbidsInventingCondition(t *testing.T) {
	prompt := identifyPrompt("a bike")
	for _, rule := range []string{"Do not invent condition", "ONLY facts"} {
		if !strings.Contains(prompt, rule) {
			t.Errorf("prompt is missing the rule %q", rule)
		}
	}
}
