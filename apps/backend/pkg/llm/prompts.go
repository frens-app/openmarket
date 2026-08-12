package llm

import "strings"

// The prompt, and the schema that constrains what comes back.
//
// Almost every rule below is here because it was measured failing, against a
// much smaller model, and written up in the README under "The on-device
// writer". They are kept because a frontier model failing less often is not the
// same as a frontier model not failing — and because the cost of each rule is a
// sentence, where the cost of the failure is a confidently wrong number under
// somebody's listing.
//
// The rules that are *not* here are the ones this design made unnecessary, and
// there are more of them than there are rules. Nothing asks the model to do
// arithmetic about a sample, because it is never shown one. Nothing asks it to
// justify a price, because it never picks one. Nothing tells it to ignore the
// comparables when naming the item, because it never sees a comparable. Each of
// those was a rule in a prompt that no longer exists, arguing with a failure
// that can no longer happen.
//
// What is left is the thing a language model is actually good at: look at a
// photograph, say what the object is, and write two paragraphs about it.

// identifySchema constrains the one call.
var identifySchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"name": map[string]any{
			"type":        "string",
			"description": "What the item is, in as few words as identify it. Brand and model where visible.",
		},
		"search_queries": map[string]any{
			"type":        "array",
			"items":       map[string]any{"type": "string"},
			"minItems":    1,
			"maxItems":    2,
			"description": "Marketplace search queries for this item, best first.",
		},
		"key_attributes": map[string]any{
			"type":        "array",
			"items":       map[string]any{"type": "string"},
			"maxItems":    6,
			"description": "Facts visible in the photo or stated by the seller.",
		},
		// The listing. maxLength on both, because a Marketplace title is a
		// single line in a grid cell and a description nobody scrolls is a
		// description nobody reads.
		"listing_title": map[string]any{
			"type":        "string",
			"maxLength":   100,
			"description": "A Facebook Marketplace listing title for this item.",
		},
		"listing_description": map[string]any{
			"type":        "string",
			"maxLength":   1200,
			"description": "The listing body. Only facts from the photo and the seller's words.",
		},
	},
	"required": []string{"name", "search_queries", "listing_title", "listing_description"},
}

// identifyPrompt asks for the identification and the listing together.
//
// Together, rather than in two calls, because they draw on exactly the same
// evidence: a photograph and whatever the seller typed. The second call used to
// write the listing *after* the market search, which added nothing — the market
// says what similar things cost, not what this thing is — while adding the one
// input that has ever poisoned this feature.
func identifyPrompt(description string) string {
	var b strings.Builder

	b.WriteString(`You identify second-hand items and write their marketplace listings.

`)

	// A photo-only run is a real case — point the camera, get a price — and the
	// difference has to be said out loud. Appending an empty description to
	// "The seller's description:" produces a prompt that appears to quote the
	// seller as saying nothing, which is a stronger invitation to fill the
	// silence than saying there was none.
	hasWords := strings.TrimSpace(description) != ""
	if hasWords {
		b.WriteString("You are given the seller's own description, and usually one or more photos.\n")
	} else {
		b.WriteString("You are given photos and nothing else. The seller wrote no description.\n")
	}

	// **Said out loud, because leaving it implicit is a known failure.** A model
	// handed three images and no framing describes three items — a dresser, a
	// drawer, and a label — which is the same mistake as taking the identity
	// from the comparables, arrived at from the other direction. Stated
	// unconditionally rather than only when photoCount > 1: this string is built
	// without knowing how many arrived, and a sentence about "the photos" costs
	// nothing on a request that carried one.
	b.WriteString(`
Any photos you are given are of ONE item, taken from different angles or showing different details. They are never several items to describe separately.
`)

	b.WriteString(`
Identify the item, write the search queries that would find comparable listings for it, and write the listing the seller will paste.

Identifying it:
- Name the item as specifically as the evidence supports. "Vitamix 5200 blender" beats "blender"; do not invent a model number you cannot see or that was not stated.
- Search queries are for finding SIMILAR items, so leave condition words out of them. "scratched", "like new" and "barely used" narrow the search without narrowing the market, and a query that returns nothing prices nothing.
- Give one query. Give a second only if the item is genuinely known by another name, and make it a different phrasing of the SAME item, never a second item or a broader category.
- key_attributes are facts you can see in the photo or that the seller stated: "six drawers", "original box", "left armrest torn".

Writing the listing:
- The title is what someone scanning a grid of photos reads. Say what the thing is, with the brand and model if you have them. It is not a sentence and it is not an advertisement.
- The description contains ONLY facts from the photo and the seller's words. Do not invent condition, history, completeness, smells, pets, or reasons for selling.
- Specifically: if the only stated fault is a scratched top, do not write that the rest is in good condition — you do not know that. If nobody said whether it works, do not say it works.
- Do not mention prices, what similar items cost, or how much of a bargain it is. You have not been told any of that, and the seller's own screen already shows them the market.
- Short and true beats long and padded. Two honest sentences is a good listing.`)

	if !hasWords {
		// The rules above lean on "the seller's words", and there are none. What
		// is left is a short list of observations — which is exactly the
		// condition under which a model starts writing the sentences it has seen
		// in a thousand listings.
		b.WriteString(`
- On this run there is no seller description at all, so the photos are everything that is known. A two-sentence listing naming the item and what is visible is the right answer; anything about condition, completeness, or how well it works would be invented.`)
	}

	if hasWords {
		b.WriteString("\n\nThe seller's description:\n" + description)
	}

	return b.String()
}
