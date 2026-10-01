package main

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
)

func TestComparisonInputRequiresUniqueCandidates(t *testing.T) {
	item := &v1.ComparisonItem{Title: "Desk", Description: "Solid wood", Condition: "Used"}
	for name, candidates := range map[string][]*v1.ComparisonCandidate{
		"empty":     nil,
		"duplicate": {{Id: "1", Item: item}, {Id: "1", Item: item}},
		"no item":   {{Id: "1"}},
		"no title":  {{Id: "1", Item: &v1.ComparisonItem{Title: " "}}},
		"no id":     {{Item: item}},
		"too many":  make([]*v1.ComparisonCandidate, 31),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := comparisonInput(&v1.EvaluateComparablesRequest{Target: item, Candidates: candidates}); err == nil {
				t.Fatal("expected invalid candidates to fail")
			}
		})
	}
	in, err := comparisonInput(&v1.EvaluateComparablesRequest{Target: item, Candidates: []*v1.ComparisonCandidate{{Id: "1", Item: item}}})
	if err != nil || in.Target.Description != "Solid wood" || in.Candidates[0].Item.Condition != "Used" {
		t.Fatalf("lost comparison context: %+v, %v", in, err)
	}
}

func TestRelevanceRequiresAuthAndConfiguredProvider(t *testing.T) {
	s := &pricingServer{}
	req := connect.NewRequest(&v1.EvaluateComparablesRequest{
		Target:     &v1.ComparisonItem{Title: "Desk"},
		Candidates: []*v1.ComparisonCandidate{{Id: "1", Item: &v1.ComparisonItem{Title: "Desk"}}},
	})
	if _, err := s.EvaluateComparables(context.Background(), req); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("expected authentication failure, got %v", err)
	}
	ctx := auth.WithUserID(context.Background(), uuid.New())
	if _, err := s.EvaluateComparables(ctx, req); connect.CodeOf(err) != connect.CodeUnavailable {
		t.Fatalf("unconfigured provider must not accept candidates, got %v", err)
	}
}
