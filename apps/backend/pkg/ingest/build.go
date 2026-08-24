package ingest

import (
	"strconv"
	"strings"
)

// BuildPolicy decides whether a client build's observations are worth having.
//
// This is the cheapest lever there is against a bad extractor. The circuit
// breaker in breaker.go reacts to a quarantine rate, which means it needs
// traffic before it can act and it acts on a whole surface. When a specific
// build is known to be producing wrong data — a parser bug found after release,
// a beta that shipped a half-finished extractor — refusing it by name discards
// exactly that data and nothing else, at the door, before a batch row exists.
//
// Nothing is stored for a refused build. The point is to throw the data out,
// not to file it.
type BuildPolicy struct {
	// Builds below this are refused. Zero disables the floor.
	//
	// The value is CURRENT_PROJECT_VERSION, which is monotonic — that is the
	// property that makes a floor meaningful, and the reason this is a number
	// rather than a version string.
	MinBuild int
	// Specific builds refused regardless of the floor, for a bad release that
	// is newer than the last good one.
	Blocked map[string]bool
}

// Configured reports whether the policy does anything. An unconfigured policy
// allows everything, so the gate can be left off until there is a build worth
// refusing.
func (p BuildPolicy) Configured() bool { return p.MinBuild > 0 || len(p.Blocked) > 0 }

// Allows reports whether observations from this build may be ingested.
//
// An empty or unparseable build is refused whenever a floor is set. A client
// that cannot say which build it is cannot show it is above the floor, and
// letting it through would make the floor advisory — which is the one thing a
// data-quality gate must not be.
func (p BuildPolicy) Allows(build string) bool {
	build = strings.TrimSpace(build)
	if p.Blocked[build] {
		return false
	}
	if p.MinBuild == 0 {
		return true
	}
	n, err := strconv.Atoi(build)
	if err != nil {
		return false
	}
	return n >= p.MinBuild
}

// ParseBlockedBuilds reads the comma-separated config value.
func ParseBlockedBuilds(raw string) map[string]bool {
	blocked := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		if build := strings.TrimSpace(part); build != "" {
			blocked[build] = true
		}
	}
	return blocked
}
