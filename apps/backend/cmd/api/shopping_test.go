package main

import (
	"context"
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

type queryEvaluator struct {
	mu      sync.Mutex
	queries []string
	invalid bool
}

func (e *queryEvaluator) Evaluate(_ context.Context, _ llm.Subject, in llm.EvaluationInput) ([]llm.Decision, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.queries = append(e.queries, in.SearchQuery)
	if e.invalid {
		return nil, nil
	}
	out := []llm.Decision{}
	for _, c := range in.Candidates {
		out = append(out, llm.Decision{ID: c.ID, UseInComparison: c.Item.Title != "Chair"})
	}
	return out, nil
}
func action(id, name, args string) llm.ShoppingMessage {
	c := llm.ShoppingCall{ID: id, Type: "function"}
	c.Function.Name = name
	c.Function.Arguments = args
	return llm.ShoppingMessage{Role: "assistant", ToolCalls: []llm.ShoppingCall{c}}
}
func setupShopping(t *testing.T, p *scriptedShopper, e *queryEvaluator) (*shoppingServer, context.Context, *v1.ShoppingSession) {
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
	return &v1.ShoppingListing{Id: id, Title: strptr(title), ObservedAtUnix: time.Now().Unix()}
}

func TestShoppingFullFrontendLoop(t *testing.T) {
	p := &scriptedShopper{replies: []llm.ShoppingMessage{
		action("s", "search", `{"query":"desk","max_price":150}`),
		action("i", "inspect_product", `{"listing_id":"desk"}`),
		action("d", "display_products", `{"products":[{"listing_id":"desk","reason":"The description says oak and drawers","caveat":"Seller claim"}]}`),
		{Role: "assistant", Content: "Here is an option."},
	}}
	e := &queryEvaluator{}
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
	if len(e.queries) != 1 || e.queries[0] != "desk" {
		t.Errorf("wrong Jev target: %v", e.queries)
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
	s, ctx, x := setupShopping(t, &scriptedShopper{}, &queryEvaluator{})
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
	s, ctx, x := setupShopping(t, p, &queryEvaluator{})
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
	s, ctx, x := setupShopping(t, p, &queryEvaluator{invalid: true})
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
func TestShoppingSearchSchemaAndCursorBinding(t *testing.T) {
	s, _, view := setupShopping(t, &scriptedShopper{}, &queryEvaluator{})
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
	s, _, v := setupShopping(t, &scriptedShopper{}, &queryEvaluator{})
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
	s, ctx, x := setupShopping(t, p, &queryEvaluator{})
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
	s, _, v := setupShopping(t, &scriptedShopper{}, &queryEvaluator{})
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
	s, ctx, v := setupShopping(t, p, &queryEvaluator{})
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
	s, ctx, x := setupShopping(t, p, &queryEvaluator{})
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
