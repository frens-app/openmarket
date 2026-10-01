package main

import (
	"context"
	"errors"
	"strings"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/llm"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

func (s *pricingServer) EvaluateComparables(ctx context.Context, req *connect.Request[v1.EvaluateComparablesRequest]) (*connect.Response[v1.EvaluateComparablesResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	in, err := comparisonInput(req.Msg)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}
	if s.relevance == nil {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("listing relevance is unavailable"))
	}
	decisions, err := s.relevance.Evaluate(ctx, llm.Subject{UserID: userID}, in)
	if err != nil {
		return nil, modelError(err, "check listing relevance")
	}
	out := &v1.EvaluateComparablesResponse{}
	for _, decision := range decisions {
		out.Decisions = append(out.Decisions, &v1.ComparableDecision{
			Id: decision.ID, UseInComparison: decision.UseInComparison, Probability: decision.Probability,
		})
	}
	return connect.NewResponse(out), nil
}

func comparisonInput(req *v1.EvaluateComparablesRequest) (llm.EvaluationInput, error) {
	in := llm.EvaluationInput{}
	if req.GetTarget() == nil || strings.TrimSpace(req.Target.Title) == "" || len(req.Candidates) == 0 || len(req.Candidates) > 30 {
		return in, errors.New("target and between 1 and 30 candidates are required")
	}
	convert := func(item *v1.ComparisonItem) llm.ComparisonItem {
		return llm.ComparisonItem{Title: item.Title, Description: item.Description, Condition: item.Condition}
	}
	in.Target = convert(req.Target)
	seen := make(map[string]bool)
	for _, candidate := range req.Candidates {
		if candidate == nil || strings.TrimSpace(candidate.Id) == "" || seen[candidate.Id] || candidate.Item == nil || strings.TrimSpace(candidate.Item.Title) == "" {
			return in, errors.New("candidates require unique IDs and nonempty titles")
		}
		seen[candidate.Id] = true
		in.Candidates = append(in.Candidates, llm.Candidate{ID: candidate.Id, Item: convert(candidate.Item)})
	}
	return in, nil
}
