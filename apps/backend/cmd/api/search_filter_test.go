package main

import (
	"context"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/llm"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
)

type searchFilterStub struct {
	err     error
	calls   int
	input   llm.SearchFilterInput
	subject llm.Subject
}

func (s *searchFilterStub) FilterSearch(_ context.Context, subject llm.Subject, in llm.SearchFilterInput) ([]llm.SearchFilterDecision, error) {
	s.calls++
	s.input = in
	s.subject = subject
	return []llm.SearchFilterDecision{{ID: "a", Verdict: llm.SearchMismatch, ImageUsed: true}}, s.err
}
func validSearchFilterRequest() *v1.FilterListingsRequest {
	return &v1.FilterListingsRequest{Query: "black desk", Candidates: []*v1.SearchFilterCandidate{{Id: "a", Title: "desk", HeadlineImageUrl: "https://scontent.fbcdn.net/p"}}}
}
func TestFilterListingsAuthenticationAvailabilityAndQuota(t *testing.T) {
	stub := &searchFilterStub{}
	s := searchServer{filter: stub}
	req := connect.NewRequest(validSearchFilterRequest())
	_, err := s.FilterListings(context.Background(), req)
	if connect.CodeOf(err) != connect.CodeUnauthenticated || stub.calls != 0 {
		t.Fatalf("unauthenticated err=%v calls=%d", err, stub.calls)
	}
	user := uuid.New()
	ctx := auth.WithUserID(context.Background(), user)
	response, err := s.FilterListings(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if stub.subject.UserID != user || stub.input.Query != "black desk" || len(response.Msg.Decisions) != 1 || response.Msg.Decisions[0].Verdict != v1.SearchFilterVerdict_SEARCH_FILTER_VERDICT_MISMATCH || !response.Msg.Decisions[0].ImageUsed {
		t.Fatal("incorrect mapping")
	}
	stub.err = llm.ErrCeilingReached
	_, err = s.FilterListings(ctx, req)
	if connect.CodeOf(err) != connect.CodeResourceExhausted {
		t.Fatalf("quota err=%v", err)
	}
	s.filter = nil
	_, err = s.FilterListings(ctx, req)
	if connect.CodeOf(err) != connect.CodeUnavailable {
		t.Fatalf("missing key err=%v", err)
	}
}
func TestSearchFilterInputBounds(t *testing.T) {
	for _, mutate := range []func(*v1.FilterListingsRequest){
		func(r *v1.FilterListingsRequest) { r.Query = " " },
		func(r *v1.FilterListingsRequest) { r.Query = strings.Repeat("a", 301) },
		func(r *v1.FilterListingsRequest) { r.Candidates = nil },
		func(r *v1.FilterListingsRequest) { r.Candidates = append(r.Candidates, r.Candidates[0]) },
		func(r *v1.FilterListingsRequest) { r.Candidates[0] = nil },
		func(r *v1.FilterListingsRequest) { r.Candidates[0].Id = " " },
		func(r *v1.FilterListingsRequest) { r.Candidates[0].Id = strings.Repeat("a", 257) },
		func(r *v1.FilterListingsRequest) { r.Candidates[0].Title = strings.Repeat("a", 501) },
		func(r *v1.FilterListingsRequest) { r.Candidates[0].HeadlineImageUrl = strings.Repeat("a", 2049) },
		func(r *v1.FilterListingsRequest) { r.Candidates = make([]*v1.SearchFilterCandidate, 21) },
	} {
		req := validSearchFilterRequest()
		mutate(req)
		if _, err := searchFilterInput(req); err == nil {
			t.Fatal("invalid input accepted")
		}
	}
	req := validSearchFilterRequest()
	req.Candidates[0].Title = ""
	req.Candidates[0].HeadlineImageUrl = ""
	if _, err := searchFilterInput(req); err != nil {
		t.Fatalf("missing evidence should remain unknown: %v", err)
	}
}
