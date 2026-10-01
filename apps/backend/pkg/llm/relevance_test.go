package llm

import (
	"context"
	"encoding/json"
	"errors"
	"frens.lol/openmarket/backend/pkg/db"
	"github.com/google/uuid"
	"go.uber.org/zap"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestJevEvaluationBatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/evaluate" || r.Method != "POST" || r.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var req evaluationRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatal(err)
		}
		if req.Model != "typesafe-ai/jev" || req.State.Description != "Working console, disc edition" || len(req.Questions) != 2 {
			t.Errorf("unexpected request: %+v", req)
		}
		if !strings.Contains(req.Questions["candidate_0"].Instructions, "PS5 console") || strings.Contains(req.Questions["candidate_0"].Instructions, "controller only") {
			t.Error("candidate questions must be isolated")
		}
		_, _ = w.Write([]byte(`{"model":"typesafe-ai/jev","answers":{"candidate_1":{"type":"boolean","probability":0.05},"candidate_0":{"type":"boolean","probability":0.8}},"usage":{"inputTokens":850,"outputTokens":0}}`))
	}))
	defer server.Close()
	j := NewJevEvaluator("test-key")
	j.baseURL = server.URL
	decisions, usage, err := j.Evaluate(context.Background(), EvaluationInput{
		Target: ComparisonItem{Title: "PlayStation 5", Description: "Working console, disc edition"},
		Candidates: []Candidate{
			{ID: "console", Item: ComparisonItem{Title: "PS5 console"}},
			{ID: "accessory", Item: ComparisonItem{Title: "controller only"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(decisions) != 2 || decisions[0].ID != "console" || !decisions[0].UseInComparison || decisions[1].ID != "accessory" || decisions[1].UseInComparison {
		t.Fatalf("incorrect decisions: %+v", decisions)
	}
	if usage.InputTokens == nil || *usage.InputTokens != 850 || usage.OutputTokens == nil || *usage.OutputTokens != 0 {
		t.Fatalf("usage must preserve zero and missing separately: %+v", usage)
	}
}

func TestJevRejectsIncompleteAndInvalidAnswers(t *testing.T) {
	for name, body := range map[string]string{
		"missing":       `{"answers":{}}`,
		"wrong id":      `{"answers":{"other":{"type":"boolean","probability":1}}}`,
		"missing value": `{"answers":{"candidate_0":{"type":"boolean"}}}`,
		"null":          `{"answers":{"candidate_0":{"type":"boolean","probability":null}}}`,
		"wrong type":    `{"answers":{"candidate_0":{"type":"score","probability":1}}}`,
		"out of range":  `{"answers":{"candidate_0":{"type":"boolean","probability":1.1}}}`,
		"negative":      `{"answers":{"candidate_0":{"type":"boolean","probability":-0.1}}}`,
		"extra":         `{"answers":{"candidate_0":{"type":"boolean","probability":1},"extra":{"type":"boolean","probability":1}}}`,
		"malformed":     `{`,
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(body)) }))
			defer server.Close()
			j := NewJevEvaluator("test-key")
			j.baseURL = server.URL
			decisions, _, err := j.Evaluate(context.Background(), EvaluationInput{Candidates: []Candidate{{ID: "a"}}})
			if CodeOf(err) != ErrorCodeInvalidOutput || decisions != nil {
				t.Fatalf("must fail closed, got %+v, %v", decisions, err)
			}
		})
	}
}

func TestJevHTTPFailures(t *testing.T) {
	for status, want := range map[int]ErrorCode{429: ErrorCodeRateLimited, 503: ErrorCodeUnavailable, 401: ErrorCodeBadRequest} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			_, _ = w.Write([]byte("private listing text"))
		}))
		j := NewJevEvaluator("test-key")
		j.baseURL = server.URL
		_, _, err := j.Evaluate(context.Background(), EvaluationInput{})
		server.Close()
		if CodeOf(err) != want || strings.Contains(err.Error(), "private listing text") {
			t.Errorf("status %d: %v", status, err)
		}
	}
}

func TestEvaluationRunnerRecordsStageAndEnforcesCeiling(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"answers":{"candidate_0":{"type":"boolean","probability":0.99}},"usage":{"inputTokens":500}}`))
	}))
	defer server.Close()
	j := NewJevEvaluator("test-key")
	j.baseURL = server.URL
	store := &fakeStore{}
	runner := NewEvaluationRunner(j, store, zap.NewNop(), Config{MaxCallsPerUser: 1, Window: time.Hour, MaxAttempts: 1, Timeout: time.Second})
	input := EvaluationInput{Candidates: []Candidate{{ID: "a"}}}
	sub := Subject{UserID: uuid.New()}
	if _, err := runner.Evaluate(context.Background(), sub, input); err != nil {
		t.Fatal(err)
	}
	if len(store.runs) != 1 || store.runs[0].Stage != db.LlmRunStageRELEVANCE || store.runs[0].Provider != "vercel" || store.runs[0].PriceCheckID != nil {
		t.Fatalf("wrong evaluation record: %+v", store.runs)
	}
	store.count = 1
	if _, err := runner.Evaluate(context.Background(), sub, input); !errors.Is(err, ErrCeilingReached) {
		t.Fatalf("expected ceiling: %v", err)
	}
	if len(store.runs) != 1 {
		t.Fatal("ceiling must prevent spending")
	}
}
