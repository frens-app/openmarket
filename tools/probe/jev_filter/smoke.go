// Run from apps/backend: go run ../../tools/probe/jev_filter/smoke.go ../../build/jev-research/dataset-0.json
// Makes one paid request through the production image downloader and Jev provider.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"frens.lol/openmarket/backend/pkg/llm"
)

func main() {
	if len(os.Args) != 2 {
		panic("provide one frozen dataset JSON path")
	}
	data, err := os.ReadFile(os.Args[1])
	must(err)
	var dataset struct {
		Query string `json:"query"`
		Cards []struct {
			ID       string `json:"id"`
			Title    string `json:"title"`
			ImageURL string `json:"image_url"`
		} `json:"cards"`
	}
	must(json.Unmarshal(data, &dataset))
	if len(dataset.Cards) == 0 || len(dataset.Cards) > 20 {
		panic("expected between 1 and 20 cards")
	}
	env, err := os.ReadFile(".env.local")
	must(err)
	var key string
	for line := range strings.SplitSeq(string(env), "\n") {
		name, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(name) == "JEV_API_KEY" {
			key = strings.Trim(strings.TrimSpace(value), "\"'")
		}
	}
	if key == "" {
		panic("JEV_API_KEY missing")
	}
	in := llm.SearchFilterInput{Query: dataset.Query}
	for _, card := range dataset.Cards {
		in.Candidates = append(in.Candidates, llm.SearchCandidate{ID: card.ID, Title: card.Title, ImageURL: card.ImageURL})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started := time.Now()
	decisions, usage, err := llm.NewJevSearchFilter(key).FilterSearch(ctx, in)
	if err != nil {
		panic("Jev smoke request failed: " + string(llm.CodeOf(err)))
	}
	result := struct {
		Query        string                     `json:"query"`
		ElapsedMS    int64                      `json:"elapsed_ms"`
		Model        string                     `json:"model"`
		InputTokens  *int32                     `json:"input_tokens"`
		EstimatedUSD float64                    `json:"estimated_usd"`
		ImagesUsed   int                        `json:"images_used"`
		Decisions    []llm.SearchFilterDecision `json:"decisions"`
	}{Query: dataset.Query, ElapsedMS: time.Since(started).Milliseconds(), Model: usage.Model, InputTokens: usage.InputTokens, Decisions: decisions}
	for _, decision := range decisions {
		if decision.ImageUsed {
			result.ImagesUsed++
		}
	}
	if usage.InputTokens != nil {
		result.EstimatedUSD = float64(*usage.InputTokens) * 0.042 / 1_000_000
	}
	encoded, err := json.MarshalIndent(result, "", "  ")
	must(err)
	fmt.Println(string(encoded))
	if result.ImagesUsed == 0 {
		os.Exit(1)
	}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
