package ingest

import "testing"

func TestBuildPolicy(t *testing.T) {
	tests := []struct {
		name   string
		policy BuildPolicy
		build  string
		want   bool
	}{
		{name: "unconfigured allows anything", policy: BuildPolicy{}, build: "", want: true},
		{name: "unconfigured allows a nonsense build", policy: BuildPolicy{}, build: "banana", want: true},

		{name: "above the floor", policy: BuildPolicy{MinBuild: 400}, build: "412", want: true},
		{name: "at the floor", policy: BuildPolicy{MinBuild: 400}, build: "400", want: true},
		{name: "below the floor", policy: BuildPolicy{MinBuild: 400}, build: "399", want: false},

		// A client that cannot say which build it is cannot show it is above the
		// floor, and a floor that lets those through is advisory.
		{name: "no build, with a floor", policy: BuildPolicy{MinBuild: 400}, build: "", want: false},
		{name: "unparseable build, with a floor", policy: BuildPolicy{MinBuild: 400}, build: "1.2.3", want: false},

		// A bad release newer than the last good one.
		{name: "blocked above the floor", policy: BuildPolicy{MinBuild: 400, Blocked: map[string]bool{"420": true}}, build: "420", want: false},
		{name: "blocked with no floor", policy: BuildPolicy{Blocked: map[string]bool{"420": true}}, build: "420", want: false},
		{name: "unblocked neighbour", policy: BuildPolicy{Blocked: map[string]bool{"420": true}}, build: "421", want: true},

		{name: "whitespace is trimmed", policy: BuildPolicy{MinBuild: 400}, build: "  412 ", want: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.policy.Allows(tt.build); got != tt.want {
				t.Fatalf("Allows(%q) = %v, want %v", tt.build, got, tt.want)
			}
		})
	}
}

func TestParseBlockedBuilds(t *testing.T) {
	blocked := ParseBlockedBuilds(" 419 , 420 ,, ")
	if len(blocked) != 2 || !blocked["419"] || !blocked["420"] {
		t.Fatalf("blocked = %v", blocked)
	}
	if len(ParseBlockedBuilds("")) != 0 {
		t.Fatal("an empty setting blocks nothing")
	}
}
