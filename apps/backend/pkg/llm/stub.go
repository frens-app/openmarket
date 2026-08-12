package llm

import (
	"context"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// StubProvider answers without calling anything.
//
// This is the local-development story, and it is the same shape as
// verify.BypassSender: a real code path that a specific configuration selects,
// not a mock wired in by a test. It exists so the iOS side of Price Check can be
// built and re-run a hundred times without a key, a network, or a bill — and so
// the recording path is exercised on every one of those runs.
//
// config.LoadAPI panics if this is selected under ENV=production, for the same
// reason DEV_BYPASS_PHONE_NUMBERS is refused there.
//
// **It reports no token counts.** The temptation is to invent plausible ones so
// the columns are populated in dev, and that is exactly backwards: the table
// exists to say what was actually spent, and seeding it with fiction to make a
// dashboard look alive is how a number nobody can trust gets into a decision.
// A `provider = 'stub'` row with NULL tokens is self-describing.
type StubProvider struct{}

func (StubProvider) Name() string { return "stub" }

// stubPhotoOnlyTerm is what a photo-only run identifies as in development.
//
// The stub cannot see, and a photo-only request gives it nothing else to work
// from — so without this it would answer with an empty name and an empty query,
// and the phone would search the marketplace for "". Naming the limitation is
// the honest answer, and it searches for something real, so the rest of the run
// still exercises the code it is there to exercise.
const stubPhotoOnlyTerm = "bookshelf"

func (StubProvider) Identify(_ context.Context, in IdentifyInput) (IdentifiedItem, Usage, error) {
	term := stubSearchTerm(in.Description)
	if term == "" {
		term = stubPhotoOnlyTerm
	}
	item := IdentifiedItem{
		Name:          stubCapitalise(term),
		SearchQueries: []string{term},
		KeyAttributes: []string{},
	}
	// Says out loud that nothing looked at the photo, so a developer testing
	// the picker sees whether the bytes arrived without believing they were
	// understood.
	if len(in.Photos) > 0 {
		item.KeyAttributes = append(item.KeyAttributes,
			fmt.Sprintf("stub: received %d photo(s), %d bytes", len(in.Photos), stubPhotoBytes(in.Photos)))
	}
	if strings.TrimSpace(in.Description) == "" {
		// Otherwise "bookshelf" looks like the stub read the photo, which is the
		// one impression this provider must never leave.
		item.KeyAttributes = append(item.KeyAttributes,
			"stub: no description, and the stub cannot see — "+stubPhotoOnlyTerm+" is a placeholder")
	}
	// The listing, said plainly to be a stub. No attempt at plausible prose:
	// copy that reads like a real listing is copy somebody screenshots into a
	// bug report, and this provider's whole job is to be obviously itself.
	item.ListingTitle = item.Name
	item.ListingBody = fmt.Sprintf(
		"Stub listing text for %s. No model was called; this is what the local stub provider returns.",
		item.Name,
	)
	return item, Usage{Model: "stub"}, nil
}

// stubCapitalise upper-cases the first rune, and survives an empty string —
// which stubSearchTerm still returns for a description that is entirely filler
// ("it is for sale"), even though the photo-only case is handled above.
func stubCapitalise(s string) string {
	for i, r := range s {
		return string(unicode.ToUpper(r)) + s[i+utf8.RuneLen(r):]
	}
	return s
}

func stubPhotoBytes(photos []Photo) int {
	total := 0
	for _, p := range photos {
		total += len(p.Data)
	}
	return total
}

// stubFiller mirrors SearchTerm.filler on the Swift side. Kept in step by hand
// and only roughly: this is a development convenience, and the moment it has to
// be exactly right is the moment it should not be a stub.
var stubFiller = map[string]bool{
	"a": true, "an": true, "the": true, "my": true, "our": true, "i": true,
	"im": true, "am": true, "is": true, "are": true, "was": true, "for": true,
	"sale": true, "selling": true, "sell": true, "with": true, "and": true,
	"in": true, "of": true, "very": true, "really": true, "great": true,
	"good": true, "nice": true, "condition": true, "used": true, "new": true,
	"barely": true, "hardly": true, "like": true, "excellent": true,
	"perfect": true, "mint": true, "some": true, "few": true, "little": true,
	"bit": true, "from": true, "home": true, "house": true, "smoke": true,
	"pet": true, "free": true, "no": true, "not": true, "it": true, "its": true,
}

// stubSearchTerm is the same trick SearchTerm.from uses: drop the filler, keep
// the first few content words. It produced the same query as a real model on
// the cases tried, which is why it survived the on-device model being removed.
func stubSearchTerm(description string) string {
	var words []string
	for _, word := range strings.FieldsFunc(strings.ToLower(description), func(r rune) bool {
		return !('a' <= r && r <= 'z') && !('0' <= r && r <= '9')
	}) {
		if stubFiller[word] {
			continue
		}
		words = append(words, word)
		if len(words) == 4 {
			break
		}
	}
	if len(words) == 0 {
		return strings.TrimSpace(description)
	}
	return strings.Join(words, " ")
}
