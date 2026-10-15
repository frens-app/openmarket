package main

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/llm"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

type searchFilterRunner interface {
	FilterSearch(context.Context, llm.Subject, llm.SearchFilterInput) ([]llm.SearchFilterDecision, error)
}
type searchServer struct{ filter searchFilterRunner }

func (s *searchServer) FilterListings(ctx context.Context, req *connect.Request[v1.FilterListingsRequest]) (*connect.Response[v1.FilterListingsResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	in, err := searchFilterInput(req.Msg)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}
	if s.filter == nil {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("AI search filtering is unavailable"))
	}
	decisions, err := s.filter.FilterSearch(ctx, llm.Subject{UserID: userID}, in)
	if err != nil {
		return nil, modelError(err, "filter search results")
	}
	out := &v1.FilterListingsResponse{}
	for _, d := range decisions {
		verdict := v1.SearchFilterVerdict_SEARCH_FILTER_VERDICT_UNKNOWN
		switch d.Verdict {
		case llm.SearchMatch:
			verdict = v1.SearchFilterVerdict_SEARCH_FILTER_VERDICT_MATCH
		case llm.SearchMismatch:
			verdict = v1.SearchFilterVerdict_SEARCH_FILTER_VERDICT_MISMATCH
		}
		out.Decisions = append(out.Decisions, &v1.SearchFilterDecision{Id: d.ID, Verdict: verdict, ImageUsed: d.ImageUsed})
	}
	return connect.NewResponse(out), nil
}

func searchFilterInput(req *v1.FilterListingsRequest) (llm.SearchFilterInput, error) {
	in := llm.SearchFilterInput{Query: strings.TrimSpace(req.GetQuery())}
	if in.Query == "" || utf8.RuneCountInString(in.Query) > 300 || len(req.GetCandidates()) < 1 || len(req.GetCandidates()) > llm.SearchFilterBatchSize {
		return in, errors.New("a query up to 300 characters and between 1 and 20 candidates are required")
	}
	seen := map[string]bool{}
	for _, c := range req.Candidates {
		if c == nil || strings.TrimSpace(c.Id) == "" || utf8.RuneCountInString(c.Id) > 256 || seen[c.Id] || utf8.RuneCountInString(c.Title) > 500 || utf8.RuneCountInString(c.HeadlineImageUrl) > 2048 {
			return in, errors.New("candidates require unique IDs and bounded card fields")
		}
		seen[c.Id] = true
		in.Candidates = append(in.Candidates, llm.SearchCandidate{ID: c.Id, Title: c.Title, ImageURL: c.HeadlineImageUrl})
	}
	return in, nil
}
