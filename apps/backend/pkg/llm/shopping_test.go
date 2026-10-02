package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestShoppingGatewayToolRoundtrip(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		if len(request["tools"]) == 0 {
			t.Error("missing tool definitions")
		}
		var messages []ShoppingMessage
		_ = json.Unmarshal(request["messages"], &messages)
		if len(messages) != 2 || messages[0].Role != "system" || messages[1].Role != "user" {
			t.Error("lost instruction roles")
		}
		_, _ = w.Write([]byte(`{"model":"test/model","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"search","arguments":"{\"query\":\"desk\"}"}}]}}],"usage":{"prompt_tokens":20,"completion_tokens":10}}`))
	}))
	defer server.Close()
	p, err := NewGatewayProvider(GatewayOptions{APIKey: "test", Model: "test/model", BaseURL: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	out, usage, err := p.Shop(context.Background(), ShoppingInput{Messages: []ShoppingMessage{{Role: "system", Content: ShoppingInstructions}, {Role: "user", Content: "desk"}}, AllowTools: true})
	if err != nil || len(out.ToolCalls) != 1 || out.ToolCalls[0].Function.Name != "search" || usage.Model != "test/model" || usage.InputTokens == nil {
		t.Fatalf("%+v %+v %v", out, usage, err)
	}
}
func TestShoppingToolsAreFlatAndLocationFree(t *testing.T) {
	props := shoppingTools()[0]["function"].(map[string]any)["parameters"].(map[string]any)["properties"].(map[string]any)
	for _, key := range []string{"description", "filters", "location", "radius", "city"} {
		if _, ok := props[key]; ok {
			t.Errorf("unexpected search argument %s", key)
		}
	}
	for _, key := range []string{"query", "min_price", "max_price", "sort", "delivery", "conditions", "listed_within_days", "availability", "cursor"} {
		if _, ok := props[key]; !ok {
			t.Errorf("missing %s", key)
		}
	}
}
func TestShoppingJevUsesOnlyQueryAsTarget(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body evaluationRequest
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.State.Title != "desk" || body.State.Description != "" {
			t.Errorf("unexpected state: %+v", body.State)
		}
		if body.Questions["candidate_0"].Criteria["true"] == "" {
			t.Error("missing query criteria")
		}
		_, _ = w.Write([]byte(`{"answers":{"candidate_0":{"type":"boolean","probability":0.9}}}`))
	}))
	defer server.Close()
	j := NewJevEvaluator("test")
	j.baseURL = server.URL
	d, _, err := j.Evaluate(context.Background(), EvaluationInput{SearchQuery: "desk", Target: ComparisonItem{Title: "unused", Description: "solid oak drawers"}, Candidates: []Candidate{{ID: "1", Item: ComparisonItem{Title: "Desk"}}}})
	if err != nil || len(d) != 1 || !d[0].UseInComparison {
		t.Fatalf("%v %v", d, err)
	}
}
