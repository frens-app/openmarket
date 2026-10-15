package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/llm"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
)

type scriptedShopper struct {
	mu      sync.Mutex
	inputs  []llm.ShoppingInput
	replies []llm.ShoppingMessage
	wait    chan struct{}
}

func (p *scriptedShopper) Shop(ctx context.Context, _ llm.Subject, in llm.ShoppingInput) (llm.ShoppingMessage, error) {
	if p.wait != nil {
		select {
		case <-p.wait:
		case <-ctx.Done():
			return llm.ShoppingMessage{}, ctx.Err()
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.inputs = append(p.inputs, in)
	if len(p.replies) == 0 {
		return llm.ShoppingMessage{Role: "assistant", Content: "Done"}, nil
	}
	r := p.replies[0]
	p.replies = p.replies[1:]
	return r, nil
}

type shoppingImageFilter struct {
	mu        sync.Mutex
	inputs    []llm.SearchFilterInput
	subjects  []llm.Subject
	transform func([]llm.SearchFilterDecision) []llm.SearchFilterDecision
	err       error
	failAt    int
	invalid   bool
}

func (e *shoppingImageFilter) FilterSearch(_ context.Context, sub llm.Subject, in llm.SearchFilterInput) ([]llm.SearchFilterDecision, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.inputs = append(e.inputs, in)
	e.subjects = append(e.subjects, sub)
	if e.err != nil && (e.failAt == 0 || len(e.inputs) == e.failAt) {
		return nil, e.err
	}
	if e.invalid {
		return nil, nil
	}
	out := []llm.SearchFilterDecision{}
	for _, c := range in.Candidates {
		verdict := llm.SearchMatch
		if c.Title == "Chair" {
			verdict = llm.SearchMismatch
		}
		if c.ImageURL == "" {
			verdict = llm.SearchUnknown
		}
		out = append(out, llm.SearchFilterDecision{ID: c.ID, Verdict: verdict, ImageUsed: c.ImageURL != ""})
	}
	if e.transform != nil {
		out = e.transform(out)
	}
	return out, nil
}
func action(id, name, args string) llm.ShoppingMessage {
	c := llm.ShoppingCall{ID: id, Type: "function"}
	c.Function.Name = name
	c.Function.Arguments = args
	return llm.ShoppingMessage{Role: "assistant", ToolCalls: []llm.ShoppingCall{c}}
}
func setupShopping(t *testing.T, p *scriptedShopper, e *shoppingImageFilter) (*shoppingServer, context.Context, *v1.ShoppingSession) {
	t.Helper()
	s := newShoppingServer(p, e, nil)
	ctx := auth.WithSessionID(auth.WithUserID(context.Background(), uuid.New()), uuid.New())
	r, err := s.StartShopping(ctx, connect.NewRequest(&v1.StartShoppingRequest{RequestId: "start", FacebookConnected: true}))
	if err != nil {
		t.Fatal(err)
	}
	return s, ctx, r.Msg.Session
}
func sendShopping(t *testing.T, s *shoppingServer, ctx context.Context, x *v1.ShoppingSession) *v1.ShoppingSession {
	t.Helper()
	r, err := s.SendShoppingMessage(ctx, connect.NewRequest(&v1.SendShoppingMessageRequest{SessionId: x.Id, RequestId: "message", Text: "Solid wood desk with drawers", SearchArea: "San Francisco, 10 km", FacebookConnected: true}))
	if err != nil {
		t.Fatal(err)
	}
	return r.Msg.Session
}
func waitShopping(t *testing.T, s *shoppingServer, ctx context.Context, id, status string) *v1.ShoppingSession {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r, err := s.GetShoppingSession(ctx, connect.NewRequest(&v1.GetShoppingSessionRequest{SessionId: id}))
		if err != nil {
			t.Fatal(err)
		}
		if r.Msg.Session.Status == status {
			return r.Msg.Session
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("did not reach %s", status)
	return nil
}
func submitShopping(t *testing.T, s *shoppingServer, ctx context.Context, x *v1.ShoppingSession, r *v1.ShoppingToolResult) {
	t.Helper()
	_, err := s.SubmitShoppingToolResult(ctx, connect.NewRequest(&v1.SubmitShoppingToolResultRequest{SessionId: x.Id, RunId: x.RunId, Result: r}))
	if err != nil {
		t.Fatal(err)
	}
}
func strptr(v string) *string { return &v }
func observation(id, title string) *v1.ShoppingListing {
	return &v1.ShoppingListing{Id: id, Title: strptr(title), ThumbnailUrl: strptr("https://scontent.fbcdn.net/" + id + ".jpg"), ObservedAtUnix: time.Now().Unix()}
}

func TestShoppingFullFrontendLoop(t *testing.T) {
	p := &scriptedShopper{replies: []llm.ShoppingMessage{
		action("s", "search", `{"query":"desk","max_price":150}`),
		action("i", "inspect_product", `{"listing_id":"desk"}`),
		action("d", "display_products", `{"products":[{"listing_id":"desk","reason":"The description says oak and drawers","caveat":"Seller claim"}]}`),
		{Role: "assistant", Content: "Here is an option."},
	}}
	e := &shoppingImageFilter{}
	s, ctx, x := setupShopping(t, p, e)
	x = sendShopping(t, s, ctx, x)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	time.Sleep(10 * time.Millisecond)
	p.mu.Lock()
	if len(p.inputs) != 1 {
		t.Error("model advanced without client data")
	}
	p.mu.Unlock()
	result := &v1.ShoppingToolResult{CallId: "s", Listings: []*v1.ShoppingListing{observation("desk", "Desk"), observation("chair", "Chair")}, HasMore: true, NextCursor: "page2", PaginationStatus: "more"}
	submitShopping(t, s, ctx, x, result)
	submitShopping(t, s, ctx, x, result)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	if len(x.Listings) != 1 || x.Listings[0].Id != "desk" {
		t.Fatalf("unfiltered cards leaked: %v", x.Listings)
	}
	detail := observation("desk", "Desk")
	detail.Detail = &v1.ShoppingDetail{Description: strptr("Solid oak with drawers, 54 inches")}
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "i", Listings: []*v1.ShoppingListing{detail}})
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "d", DisplayedIds: []string{"desk"}})
	x = waitShopping(t, s, ctx, x.Id, "completed")
	if len(x.Messages) != 2 || x.Messages[1].GetDisplay() == nil {
		t.Fatalf("missing display or duplicate message: %v", x.Messages)
	}
	e.mu.Lock()
	if len(e.inputs) != 1 || e.inputs[0].Query != "desk" {
		t.Errorf("wrong Jev target: %v", e.inputs)
	}
	e.mu.Unlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.inputs) != 3 {
		t.Fatalf("duplicate continuation: %d", len(p.inputs))
	}
	for _, in := range p.inputs {
		for _, m := range in.Messages {
			if strings.Contains(m.Content, `"Chair"`) {
				t.Error("rejected body reached assistant")
			}
		}
	}
}
func TestShoppingOwnershipExpiryAndStartIdempotency(t *testing.T) {
	s, ctx, x := setupShopping(t, &scriptedShopper{}, &shoppingImageFilter{})
	r, err := s.StartShopping(ctx, connect.NewRequest(&v1.StartShoppingRequest{RequestId: "start", FacebookConnected: true}))
	if err != nil || r.Msg.Session.Id != x.Id {
		t.Fatal("start retry was not idempotent")
	}
	other := auth.WithSessionID(auth.WithUserID(context.Background(), uuid.New()), uuid.New())
	if _, err := s.GetShoppingSession(other, connect.NewRequest(&v1.GetShoppingSessionRequest{SessionId: x.Id})); connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatal("other account could access chat")
	}
	now := time.Now().Add(31 * time.Minute)
	s.now = func() time.Time { return now }
	if _, err := s.GetShoppingSession(ctx, connect.NewRequest(&v1.GetShoppingSessionRequest{SessionId: x.Id})); connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatal("expired session survived")
	}
}
func TestShoppingCancellationRejectsLateWork(t *testing.T) {
	p := &scriptedShopper{wait: make(chan struct{}), replies: []llm.ShoppingMessage{action("s", "search", `{"query":"desk"}`)}}
	s, ctx, x := setupShopping(t, p, &shoppingImageFilter{})
	x = sendShopping(t, s, ctx, x)
	_, err := s.ControlShoppingSession(ctx, connect.NewRequest(&v1.ControlShoppingSessionRequest{SessionId: x.Id, RunId: x.RunId, Action: "stop"}))
	if err != nil {
		t.Fatal(err)
	}
	close(p.wait)
	time.Sleep(10 * time.Millisecond)
	x = waitShopping(t, s, ctx, x.Id, "cancelled")
	if len(x.PendingCalls) > 0 {
		t.Fatal("late model response restarted run")
	}
	_, err = s.SubmitShoppingToolResult(ctx, connect.NewRequest(&v1.SubmitShoppingToolResultRequest{SessionId: x.Id, RunId: x.RunId, Result: &v1.ShoppingToolResult{CallId: "s"}}))
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatal("late result accepted")
	}
}
func TestShoppingFilteringFailureDoesNotSupplyCards(t *testing.T) {
	p := &scriptedShopper{replies: []llm.ShoppingMessage{action("s", "search", `{"query":"desk"}`)}}
	s, ctx, x := setupShopping(t, p, &shoppingImageFilter{invalid: true})
	x = sendShopping(t, s, ctx, x)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "s", Listings: []*v1.ShoppingListing{observation("d", "Desk")}, PaginationStatus: "exhausted"})
	x = waitShopping(t, s, ctx, x.Id, "completed")
	if len(x.Listings) > 0 {
		t.Fatal("invalid Jev batch leaked cards")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	found := false
	for _, m := range p.inputs[1].Messages {
		if strings.Contains(m.Content, "filtering failed") {
			found = true
		}
	}
	if !found {
		t.Fatal("filter error was concealed from model")
	}
}

func TestShoppingImageFilteringBatchesCardsAndPreservesUncertainty(t *testing.T) {
	p := &scriptedShopper{replies: []llm.ShoppingMessage{action("s", "search", `{"query":"black standing desk"}`)}}
	e := &shoppingImageFilter{transform: func(ds []llm.SearchFilterDecision) []llm.SearchFilterDecision {
		for i := range ds {
			if ds[i].ID == "desk-1" {
				ds[i].Verdict = llm.SearchUnknown
			}
		}
		return ds
	}}
	s, ctx, x := setupShopping(t, p, e)
	x = sendShopping(t, s, ctx, x)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	var cards []*v1.ShoppingListing
	for i := range 41 {
		cards = append(cards, observation(fmt.Sprintf("desk-%d", i), "Standing desk"))
	}
	cards[0].ThumbnailUrl = nil
	cards[2].Title = strptr("Chair")
	r := &v1.ShoppingToolResult{CallId: "s", Listings: cards, HasMore: true, NextCursor: "next", PaginationStatus: "more"}
	submitShopping(t, s, ctx, x, r)
	x = waitShopping(t, s, ctx, x.Id, "completed")
	submitShopping(t, s, ctx, x, r)
	if len(x.Listings) != 40 {
		t.Fatalf("want matches and unknowns, got %d cards", len(x.Listings))
	}
	owner, _ := auth.UserID(ctx)
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.inputs) != 3 {
		t.Fatalf("want three batches, no extra call for duplicate submission: %d", len(e.inputs))
	}
	for i, size := range []int{20, 20, 1} {
		if e.inputs[i].Query != "black standing desk" || len(e.inputs[i].Candidates) != size || e.subjects[i].UserID != owner {
			t.Fatalf("wrong query, batch, or billing subject: %+v", e.inputs[i])
		}
	}
	if c := e.inputs[0].Candidates[1]; c.ID != cards[1].Id || c.Title != cards[1].GetTitle() || c.ImageURL != cards[1].GetThumbnailUrl() {
		t.Fatalf("headline image was not forwarded with its card: %+v", c)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	var outcome struct {
		Result          json.RawMessage            `json:"result"`
		Fetched         int                        `json:"fetched"`
		Rejected        int                        `json:"rejected"`
		FilterDecisions []llm.SearchFilterDecision `json:"filter_decisions"`
	}
	for _, m := range p.inputs[1].Messages {
		if m.Role == "tool" && m.ToolCallID == "s" {
			if err := json.Unmarshal([]byte(m.Content), &outcome); err != nil {
				t.Fatal(err)
			}
		}
	}
	if outcome.Fetched != 41 || outcome.Rejected != 1 || len(outcome.FilterDecisions) != 40 {
		t.Fatalf("incorrect filtering counts or evidence: %+v", outcome)
	}
	if outcome.FilterDecisions[0].Verdict != llm.SearchUnknown || outcome.FilterDecisions[0].ImageUsed ||
		outcome.FilterDecisions[1].Verdict != llm.SearchUnknown || !outcome.FilterDecisions[1].ImageUsed {
		t.Fatal("assistant cannot distinguish missing images from uncertain visual decisions")
	}
	if strings.Contains(string(outcome.Result), "Chair") || !strings.Contains(string(outcome.Result), "next") {
		t.Fatal("rejected content leaked or continuation was lost")
	}
}

func TestShoppingImageFilteringRejectsInvalidAndFailedBatches(t *testing.T) {
	for name, filter := range map[string]*shoppingImageFilter{
		"unknown ID":      {transform: func(ds []llm.SearchFilterDecision) []llm.SearchFilterDecision { ds[0].ID = "invented"; return ds }},
		"duplicate ID":    {transform: func(ds []llm.SearchFilterDecision) []llm.SearchFilterDecision { ds[1].ID = ds[0].ID; return ds }},
		"invalid verdict": {transform: func(ds []llm.SearchFilterDecision) []llm.SearchFilterDecision { ds[0].Verdict = "invalid"; return ds }},
		"mismatch without image": {transform: func(ds []llm.SearchFilterDecision) []llm.SearchFilterDecision {
			ds[0].Verdict = llm.SearchMismatch
			ds[0].ImageUsed = false
			return ds
		}},
		"quota":                {err: llm.ErrCeilingReached},
		"second batch timeout": {err: context.DeadlineExceeded, failAt: 2},
	} {
		t.Run(name, func(t *testing.T) {
			p := &scriptedShopper{replies: []llm.ShoppingMessage{action("s", "search", `{"query":"desk"}`)}}
			s, ctx, x := setupShopping(t, p, filter)
			x = sendShopping(t, s, ctx, x)
			x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
			var cards []*v1.ShoppingListing
			for i := range 21 {
				cards = append(cards, observation(fmt.Sprintf("desk-%d", i), "Private card title"))
			}
			submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "s", Listings: cards, PaginationStatus: "exhausted"})
			x = waitShopping(t, s, ctx, x.Id, "completed")
			if len(x.Listings) != 0 {
				t.Fatal("failed page exposed partial results")
			}
			p.mu.Lock()
			defer p.mu.Unlock()
			for _, m := range p.inputs[1].Messages {
				if m.Role == "tool" {
					if !strings.Contains(m.Content, `"error"`) || strings.Contains(m.Content, "Private card title") {
						t.Fatalf("failed evaluation was concealed or leaked cards: %s", m.Content)
					}
				}
			}
		})
	}
}

func TestShoppingRequiresImageFilterConfiguration(t *testing.T) {
	s := newShoppingServer(&scriptedShopper{}, nil, nil)
	ctx := auth.WithUserID(context.Background(), uuid.New())
	_, err := s.StartShopping(ctx, connect.NewRequest(&v1.StartShoppingRequest{RequestId: "start", FacebookConnected: true}))
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("AI Search silently started without the image filter: %v", err)
	}
}
func TestShoppingSearchSchemaAndCursorBinding(t *testing.T) {
	s, _, view := setupShopping(t, &scriptedShopper{}, &shoppingImageFilter{})
	x := s.sessions[view.Id]
	for _, args := range []string{`{"query":"desk","location":"Paris"}`, `{"query":"desk","filters":{}}`, `{"query":"desk","description":"wood"}`, `{"query":"desk","max_price":-1}`, `{"query":"desk","cursor":"invented"}`, `{"query":"desk","sort":"random"}`} {
		if _, err := s.parseCall(x, action("s", "search", args).ToolCalls[0]); err == nil {
			t.Errorf("accepted %s", args)
		}
	}
	q := &v1.ShoppingSearch{Query: "desk", Sort: "best_match", Delivery: "any", Availability: "available"}
	x.cursors["next"] = searchKey(q)
	if _, err := s.parseCall(x, action("s", "search", `{"query":"desk","cursor":"next"}`).ToolCalls[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := s.parseCall(x, action("s", "search", `{"query":"chair","cursor":"next"}`).ToolCalls[0]); err == nil {
		t.Fatal("cursor transferred to another query")
	}
}
func TestShoppingInspectionAndDisplayValidation(t *testing.T) {
	call := &v1.ShoppingToolCall{Action: &v1.ShoppingToolCall_Inspect{Inspect: &v1.ShoppingInspect{ListingId: "desk"}}}
	wrong := observation("chair", "Chair")
	wrong.Detail = &v1.ShoppingDetail{}
	if validateShoppingResult(call, &v1.ShoppingToolResult{Listings: []*v1.ShoppingListing{wrong}}) == nil {
		t.Fatal("wrong product inspection accepted")
	}
	s, _, v := setupShopping(t, &scriptedShopper{}, &shoppingImageFilter{})
	x := s.sessions[v.Id]
	sold := true
	x.known["desk"] = observation("desk", "Desk")
	x.known["desk"].Detail = &v1.ShoppingDetail{IsSold: &sold}
	if _, err := s.parseCall(x, action("d", "display_products", `{"products":[{"listing_id":"desk"}]}`).ToolCalls[0]); err == nil {
		t.Fatal("sold product recommended")
	}
}
func TestShoppingPauseBlocksContinuationUntilResume(t *testing.T) {
	p := &scriptedShopper{replies: []llm.ShoppingMessage{action("s", "search", `{"query":"desk"}`)}}
	s, ctx, x := setupShopping(t, p, &shoppingImageFilter{})
	x = sendShopping(t, s, ctx, x)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	_, err := s.ControlShoppingSession(ctx, connect.NewRequest(&v1.ControlShoppingSessionRequest{SessionId: x.Id, RunId: x.RunId, Action: "pause"}))
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.SubmitShoppingToolResult(ctx, connect.NewRequest(&v1.SubmitShoppingToolResultRequest{SessionId: x.Id, RunId: x.RunId, Result: &v1.ShoppingToolResult{CallId: "s", PaginationStatus: "exhausted"}}))
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatal("paused run accepted new work")
	}
	_, err = s.ControlShoppingSession(ctx, connect.NewRequest(&v1.ControlShoppingSessionRequest{SessionId: x.Id, RunId: x.RunId, Action: "resume"}))
	if err != nil {
		t.Fatal(err)
	}
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "s", PaginationStatus: "exhausted"})
	waitShopping(t, s, ctx, x.Id, "completed")
}

func TestShoppingReducedBudgetsAndDuplicateWork(t *testing.T) {
	s, _, v := setupShopping(t, &scriptedShopper{}, &shoppingImageFilter{})
	x := s.sessions[v.Id]
	x.started = time.Now()
	search := action("s1", "search", `{"query":"desk"}`).ToolCalls[0]
	if _, err := s.parseCall(x, search); err != nil {
		t.Fatal(err)
	}
	search.ID = "s2"
	if _, err := s.parseCall(x, search); err == nil {
		t.Fatal("duplicate page would refetch Marketplace")
	}
	if _, err := s.parseCall(x, action("s3", "search", `{"query":"writing desk"}`).ToolCalls[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := s.parseCall(x, action("s4", "search", `{"query":"office desk"}`).ToolCalls[0]); err == nil {
		t.Fatal("third source page was allowed")
	}
	for _, id := range []string{"a", "b", "c", "d"} {
		x.known[id] = observation(id, "Desk")
	}
	for _, id := range []string{"a", "b", "c"} {
		if _, err := s.parseCall(x, action("inspect-"+id, "inspect_product", `{"listing_id":"`+id+`"}`).ToolCalls[0]); err != nil {
			t.Fatal(err)
		}
		if id == "a" {
			if _, err := s.parseCall(x, action("repeat", "inspect_product", `{"listing_id":"a"}`).ToolCalls[0]); err == nil {
				t.Fatal("repeated inspection allowed")
			}
		}
	}
	if _, err := s.parseCall(x, action("extra", "inspect_product", `{"listing_id":"d"}`).ToolCalls[0]); err == nil {
		t.Fatal("fourth inspection was allowed")
	}
	x.started = time.Now().Add(-2 * time.Minute)
	if _, err := s.parseCall(x, action("display", "display_products", `{"products":[{"listing_id":"a"}]}`).ToolCalls[0]); err != nil {
		t.Fatalf("time limit prevented displaying existing evidence: %v", err)
	}
}

func TestShoppingClosingCallCanOnlyDisplay(t *testing.T) {
	p := &scriptedShopper{}
	s, ctx, v := setupShopping(t, p, &shoppingImageFilter{})
	s.mu.Lock()
	x := s.sessions[v.Id]
	x.view.RunId = "run"
	x.calls = shoppingPlanningCalls
	x.started = time.Now()
	x.known["desk"] = observation("desk", "Desk")
	s.plan(x)
	s.mu.Unlock()
	waitShopping(t, s, ctx, v.Id, "completed")
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.inputs) != 1 || len(p.inputs[0].AllowedTools) != 1 || p.inputs[0].AllowedTools[0] != "display_products" {
		t.Fatalf("closing call can retrieve more products: %+v", p.inputs)
	}
}

func TestShoppingDisplaySkipsAdditionalRequestsInSameBatch(t *testing.T) {
	display := action("display", "display_products", `{"products":[{"listing_id":"desk"}]}`)
	display.ToolCalls = append(display.ToolCalls, action("extra", "search", `{"query":"writing desk"}`).ToolCalls[0])
	p := &scriptedShopper{replies: []llm.ShoppingMessage{action("search", "search", `{"query":"desk"}`), display}}
	s, ctx, x := setupShopping(t, p, &shoppingImageFilter{})
	x = sendShopping(t, s, ctx, x)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "search", Listings: []*v1.ShoppingListing{observation("desk", "Desk")}, PaginationStatus: "exhausted"})
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	if len(x.PendingCalls) != 1 || x.PendingCalls[0].GetDisplay() == nil {
		t.Fatalf("unnecessary search queued: %v", x.PendingCalls)
	}
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "display", DisplayedIds: []string{"desk"}})
	waitShopping(t, s, ctx, x.Id, "completed")
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.inputs) != 2 {
		t.Fatal("model called again after display")
	}
}

func TestShoppingDisplayAcknowledgmentAlreadyContainsRenderedResults(t *testing.T) {
	p := &scriptedShopper{replies: []llm.ShoppingMessage{
		action("search", "search", `{"query":"desk"}`),
		action("display", "display_products", `{"title":"Your options","products":[{"listing_id":"desk"}]}`),
	}}
	s, ctx, x := setupShopping(t, p, &shoppingImageFilter{})
	x = sendShopping(t, s, ctx, x)
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	submitShopping(t, s, ctx, x, &v1.ShoppingToolResult{CallId: "search", Listings: []*v1.ShoppingListing{observation("desk", "Desk")}, PaginationStatus: "exhausted"})
	x = waitShopping(t, s, ctx, x.Id, "awaiting_client")
	request := connect.NewRequest(&v1.SubmitShoppingToolResultRequest{
		SessionId: x.Id, RunId: x.RunId,
		Result: &v1.ShoppingToolResult{CallId: "display", DisplayedIds: []string{"desk"}},
	})
	request.Msg.Result.DisplayedIds = []string{"wrong"}
	if _, err := s.SubmitShoppingToolResult(ctx, request); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("invalid display acknowledgment was accepted: %v", err)
	}
	request.Msg.Result.DisplayedIds = []string{"desk"}
	for range 2 {
		response, err := s.SubmitShoppingToolResult(ctx, request)
		if err != nil {
			t.Fatal(err)
		}
		view := response.Msg.Session
		if view.Status != "completed" || len(view.PendingCalls) != 0 {
			t.Fatalf("display acknowledgment requires another poll: status=%s pending=%d", view.Status, len(view.PendingCalls))
		}
		var displays int
		for _, message := range view.Messages {
			if message.Id == "display" && message.GetDisplay() != nil {
				displays++
			}
		}
		if displays != 1 || len(view.Listings) != 1 || view.Listings[0].Id != "desk" {
			t.Fatalf("optimistic cards would disappear or duplicate on acknowledgment: %+v", view)
		}
	}
}
