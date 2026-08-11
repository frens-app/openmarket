package llm

import (
	"encoding/json"
	"strings"
	"testing"
)

// The schemas are sent to a provider verbatim, so a construct that is legal
// JSON Schema but illegal to the provider is a 400 on every call — not a bad
// answer on some of them. A fake HTTP server will never catch that, because a
// fake accepts whatever it is handed. These tests stand in for the checks the
// provider does, and each one is here because it was seen failing against the
// real thing.

// Vertex rejects the whole request with
//
//	response_schema.properties[condition].enum[0]: cannot be empty
//
// so "unknown" cannot be spelled as an empty enum member. It is spelled by
// leaving the field out instead — which is why nothing optional may be
// required, checked below.
func TestSchemasHaveNoEmptyEnumMembers(t *testing.T) {
	for name, schema := range map[string]map[string]any{
		"identify": identifySchema,
		"price":    priceSchema,
	} {
		props, _ := schema["properties"].(map[string]any)
		for field, raw := range props {
			spec, _ := raw.(map[string]any)
			values, ok := spec["enum"].([]string)
			if !ok {
				continue
			}
			for i, v := range values {
				if strings.TrimSpace(v) == "" {
					t.Errorf("%s schema: %s.enum[%d] is empty; omit the field instead", name, field, i)
				}
			}
		}
	}
}

// condition is the field with no empty member, so the model has to be free to
// say nothing at all. Requiring it would force a guess.
func TestIdentifySchemaLeavesConditionOptional(t *testing.T) {
	required, _ := identifySchema["required"].([]string)
	for _, field := range required {
		if field == "condition" {
			t.Fatal("condition is required, but it has no value meaning 'unknown'")
		}
	}
}

// Both schemas cross the wire as JSON. A map that cannot be marshalled fails at
// the request, after the photo has already been uploaded and the user is
// waiting.
func TestSchemasMarshal(t *testing.T) {
	for name, schema := range map[string]map[string]any{
		"identify": identifySchema,
		"price":    priceSchema,
	} {
		if _, err := json.Marshal(schema); err != nil {
			t.Errorf("%s schema does not marshal: %v", name, err)
		}
	}
}

// The identify prompt tells the model to omit condition. If that sentence ever
// goes back to saying "leave it empty", the schema and the prompt disagree and
// the model is being asked for a value the schema forbids.
func TestIdentifyPromptDoesNotAskForAnEmptyCondition(t *testing.T) {
	prompt := strings.ToLower(identifyPrompt("a red bicycle"))
	if !strings.Contains(prompt, "omit the field") {
		t.Error("identify prompt should tell the model to omit condition, not to empty it")
	}
	if !strings.Contains(prompt, "a red bicycle") {
		t.Error("the seller's description is missing from the prompt")
	}
}
