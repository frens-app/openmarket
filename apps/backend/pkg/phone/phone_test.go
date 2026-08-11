package phone

import (
	"errors"
	"strings"
	"testing"
)

func TestNewAllowlistRejectsEmpty(t *testing.T) {
	// Failing closed is the whole contract: a missing env var must not become
	// "send SMS to any country on earth".
	for _, raw := range []string{"", "   ", ",,", " , "} {
		if _, err := NewAllowlist(raw); err == nil {
			t.Fatalf("NewAllowlist(%q) = nil error, want error", raw)
		}
	}
}

func TestNewAllowlistParsesCodes(t *testing.T) {
	a, err := NewAllowlist(" 1, +44 ,351,1")
	if err != nil {
		t.Fatalf("NewAllowlist: %v", err)
	}
	got := strings.Join(a.Codes(), ",")
	// Longest first, deduplicated, '+' stripped.
	if got != "351,44,1" {
		t.Fatalf("Codes() = %q, want %q", got, "351,44,1")
	}
}

func TestNewAllowlistRejectsGarbage(t *testing.T) {
	// ITU calling codes are one to three digits, so a longer token is a
	// configuration mistake — most likely a whole phone number pasted in.
	for _, raw := range []string{"US", "1x", "1242", "12345", "+"} {
		if _, err := NewAllowlist(raw); err == nil {
			t.Fatalf("NewAllowlist(%q) = nil error, want error", raw)
		}
	}
}

func TestParse(t *testing.T) {
	a, err := NewAllowlist("1,44,351")
	if err != nil {
		t.Fatalf("NewAllowlist: %v", err)
	}

	t.Run("normalises formatting", func(t *testing.T) {
		num, err := a.Parse(" +1 (415) 555-0123 ")
		if err != nil {
			t.Fatalf("Parse: %v", err)
		}
		if num.E164 != "+14155550123" {
			t.Fatalf("E164 = %q, want %q", num.E164, "+14155550123")
		}
		if num.CountryCode != "1" {
			t.Fatalf("CountryCode = %q, want %q", num.CountryCode, "1")
		}
	})

	t.Run("multi-digit codes resolve", func(t *testing.T) {
		num, err := a.Parse("+351212345678")
		if err != nil {
			t.Fatalf("Parse: %v", err)
		}
		if num.CountryCode != "351" {
			t.Fatalf("CountryCode = %q, want %q", num.CountryCode, "351")
		}
	})

	t.Run("longest prefix wins", func(t *testing.T) {
		// Real ITU codes are prefix-free, so this can only arise from a
		// misconfigured list. Sorting longest-first means such a list degrades
		// into the more specific bucket rather than silently attributing every
		// number to the shorter code and flattening the per-country limit.
		overlapping, err := NewAllowlist("1,15")
		if err != nil {
			t.Fatalf("NewAllowlist: %v", err)
		}
		num, err := overlapping.Parse("+15105550123")
		if err != nil {
			t.Fatalf("Parse: %v", err)
		}
		if num.CountryCode != "15" {
			t.Fatalf("CountryCode = %q, want %q", num.CountryCode, "15")
		}
	})

	t.Run("rejects unserved country", func(t *testing.T) {
		_, err := a.Parse("+493012345678")
		var notAllowed ErrNotAllowed
		if !errors.As(err, &notAllowed) {
			t.Fatalf("Parse(+49…) error = %v, want ErrNotAllowed", err)
		}
	})

	t.Run("rejects malformed", func(t *testing.T) {
		for _, raw := range []string{"", "4155550123", "+0155550123", "+1", "not a number"} {
			if _, err := a.Parse(raw); err == nil {
				t.Fatalf("Parse(%q) = nil error, want error", raw)
			}
		}
	})

	t.Run("accepts short national numbers", func(t *testing.T) {
		// National number lengths vary widely and the carrier is the only
		// authority on reachability, so anything past E.164's own floor is left
		// to the provider rather than guessed at here.
		if _, err := a.Parse("+35121234567"); err != nil {
			t.Fatalf("Parse: %v", err)
		}
	})
}

func TestMaskHidesTheNumber(t *testing.T) {
	a, _ := NewAllowlist("1")
	num, err := a.Parse("+14155550123")
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	masked := num.Mask()
	if strings.Contains(masked, "4155550") {
		t.Fatalf("Mask() = %q, still contains the subscriber number", masked)
	}
	if !strings.HasPrefix(masked, "+1") || !strings.HasSuffix(masked, "23") {
		t.Fatalf("Mask() = %q, want +1…23", masked)
	}
}
