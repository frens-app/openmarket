package llm

import (
	"context"
	"os"
	"testing"
	"time"
)

// Opt-in only: JEV_LIVE_API_KEY enables a billed check using synthetic listings.
func TestJevLive(t *testing.T) {
	key := os.Getenv("JEV_LIVE_API_KEY")
	if key == "" {
		t.Skip("set JEV_LIVE_API_KEY to run the gateway smoke test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	started := time.Now()
	decisions, usage, err := NewJevEvaluator(key).Evaluate(ctx, EvaluationInput{
		Target: ComparisonItem{Title: "Sony PlayStation 5 disc edition console", Description: "Working PS5 with one controller and cables", Condition: "Used - Good"},
		Candidates: []Candidate{
			{ID: "match", Item: ComparisonItem{Title: "PS5 disc edition with controller", Description: "Works perfectly, includes power and HDMI cables", Condition: "Used - Good"}},
			{ID: "accessory", Item: ComparisonItem{Title: "PS5 controller only", Description: "DualSense controller, console not included"}},
			{ID: "generation", Item: ComparisonItem{Title: "PlayStation 4 console", Description: "Working PS4 with one controller"}},
			{ID: "broken", Item: ComparisonItem{Title: "PS5 disc console for parts", Description: "Does not turn on, broken motherboard"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, decision := range decisions {
		t.Logf("%s: included=%t probability=%.3f", decision.ID, decision.UseInComparison, decision.Probability)
		if decision.UseInComparison != (decision.ID == "match") {
			t.Errorf("unexpected classification for %s", decision.ID)
		}
	}
	if usage.InputTokens != nil {
		t.Logf("model=%s input_tokens=%d elapsed=%s", usage.Model, *usage.InputTokens, time.Since(started))
	}
}

func TestJevLiveSwitch(t *testing.T) {
	key := os.Getenv("JEV_LIVE_API_KEY")
	if key == "" {
		t.Skip("set JEV_LIVE_API_KEY to run the gateway regression test")
	}
	titles := []string{
		"Nintendo Switch 1", "Nintendo Switch with Gray Joy-Cons", "Nintendo Switch 1 (Unopened)",
		"Nintendo Switch Bundle + Zelda & Super Smash Bros", "Nintendo Switch with Accessories",
		"Nintendo Switch 2", "Nintendo Switch OLED bundle 256GB P8PY",
		"Nintendo Switch 1 Non-OLED HAC-001(-01) Improved Battery, Gray Joy-Cons + Dock",
		"Nintendo Switch 1 $115", "Nintendo Switch Console", "Nintendo switch 2 for sale", "Switch 2,again",
		"Nintendo Switch 2 (Console and Power Adapter ONLY!!!!)",
		"Nintendo Switch Bundle with Ring Fit Adventure and Accessories", "Nintendo Switch + Games",
		"Nintendo Switch OLED Bundle – Complete Ready-to-Play Set + Official Pro Controller",
		"Nintendo Switch Console with Dock and Case", "Nintendo Switch V2 32GB + Dock, Joy-Cons, Charger – Excellent Condition",
		"Nintendo Switch", "Nintendo Switch Console Bundle", "v1 Nintendo Switch + case + 256GB MicroSD",
		"Nintendo Switch carrying case only", "Nintendo Switch broken for parts", "Nintendo Switch Lite",
	}
	in := EvaluationInput{Target: ComparisonItem{Title: "Nintendo Switch", Description: "Nintendo switch 1\nleft joystick rubber is eroded.\nfactory reset\ndock included\nvenmo preferred, $100 obo"}}
	for _, title := range titles {
		in.Candidates = append(in.Candidates, Candidate{ID: title, Item: ComparisonItem{Title: title}})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	decisions, _, err := NewJevEvaluator(key).Evaluate(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	excluded := map[string]bool{
		"Nintendo Switch 2":                                      true,
		"Nintendo Switch OLED bundle 256GB P8PY":                 true,
		"Nintendo switch 2 for sale":                             true,
		"Switch 2,again":                                         true,
		"Nintendo Switch 2 (Console and Power Adapter ONLY!!!!)": true,
		"Nintendo Switch OLED Bundle – Complete Ready-to-Play Set + Official Pro Controller": true,
		"Nintendo Switch carrying case only":                                                 true,
		"Nintendo Switch broken for parts":                                                   true,
		"Nintendo Switch Lite":                                                               true,
	}
	for _, d := range decisions {
		t.Logf("%.3f included=%t %s", d.Probability, d.UseInComparison, d.ID)
		if d.UseInComparison == excluded[d.ID] {
			t.Errorf("incorrect inclusion for %s", d.ID)
		}
	}
}
