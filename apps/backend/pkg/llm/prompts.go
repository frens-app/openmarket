package llm

import (
	"fmt"
	"strings"
)

// The prompts, and the schemas that constrain what comes back.
//
// Almost every rule below is here because it was measured failing, against a
// much smaller model, and written up in the README under "The on-device
// writer". They are kept because a frontier model failing less often is not the
// same as a frontier model not failing — and because the cost of each rule is a
// sentence, where the cost of the failure is a confidently wrong number under
// somebody's listing.
//
// The rules that are *not* here are the ones this design made unnecessary. The
// model is never asked to do arithmetic about the sample, because Swift already
// did it. It is never asked to justify the price in numbers, because
// `PriceGuide.explanation` writes that sentence. And nothing tells it to ignore
// the comparables when naming the item, because by the time it sees any
// comparables the item is already named.

// identifySchema constrains the first call.
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
		// No empty member. "Unknown" is expressed by leaving the field out —
		// condition is not in `required` — because an empty string is not a legal
		// enum value: Vertex rejects the whole request with
		// `response_schema.properties[condition].enum[0]: cannot be empty`, and a
		// 400 on the schema fails every call, not just the uncertain ones.
		"condition": map[string]any{
			"type": "string",
			"enum": []string{"new", "used_like_new", "used_good", "used_fair"},
		},
		"key_attributes": map[string]any{
			"type":     "array",
			"items":    map[string]any{"type": "string"},
			"maxItems": 6,
		},
	},
	"required": []string{"name", "search_queries"},
}

// priceSchema constrains the second call. `price` is in whole units — see the
// conversion note in GeminiProvider.Price.
var priceSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"price": map[string]any{
			"type":        "integer",
			"description": "The asking price, a whole number, in the same units as the prices given.",
		},
		"title":       map[string]any{"type": "string", "maxLength": 100},
		"description": map[string]any{"type": "string", "maxLength": 1200},
	},
	"required": []string{"price", "title", "description"},
}

func identifyPrompt(description string) string {
	// A photo-only run is a real case — point the camera, get a price — and the
	// difference has to be said out loud. Appending an empty description to
	// "The seller's description:" produces a prompt that appears to quote the
	// seller as saying nothing, which is a stronger invitation to fill the
	// silence than saying there was none.
	if strings.TrimSpace(description) == "" {
		return `You identify second-hand items so they can be priced against a local marketplace.

You are given a photo and nothing else. Identify the item and write the search queries that would find comparable listings for it.

Rules:
- Name the item as specifically as the photo supports. "Vitamix 5200 blender" beats "blender"; do not invent a model number you cannot actually read in the image.
- Search queries are for finding SIMILAR items, so leave condition words out of them. "scratched", "like new" and "barely used" narrow the search without narrowing the market, and a query that returns nothing prices nothing.
- Give one query. Give a second only if the item is genuinely known by another name, and make it a different phrasing of the SAME item, never a second item or a broader category.
- key_attributes are things you can SEE. "six drawers", "original box", "left armrest torn". You have no seller to tell you anything else, so anything not visible in the photo does not exist as far as this answer is concerned.
- condition is a guess from the photo. Omit the field entirely rather than guess blindly; it is optional, and "no answer" is a better answer than a wrong one.`
	}

	return `You identify second-hand items so they can be priced against a local marketplace.

You are given the seller's own description, and usually a photo. Identify the item and write the search queries that would find comparable listings for it.

Rules:
- Name the item as specifically as the evidence supports. "Vitamix 5200 blender" beats "blender"; do not invent a model number you cannot see or that was not stated.
- Search queries are for finding SIMILAR items, so leave condition words out of them. "scratched", "like new" and "barely used" narrow the search without narrowing the market, and a query that returns nothing prices nothing.
- Give one query. Give a second only if the item is genuinely known by another name, and make it a different phrasing of the SAME item, never a second item or a broader category.
- key_attributes are facts you can see in the photo or that the seller stated: "six drawers", "original box", "left armrest torn". Do not add condition you cannot see. If the seller mentions one scratch, that is one scratch, and the rest of the item is not "in good condition" as far as you know.
- condition is a guess from the photo. Omit the field entirely rather than guess blindly; it is optional, and "no answer" is a better answer than a wrong one.

The seller's description:
` + description
}

func pricePrompt(in PriceInput) string {
	var b strings.Builder

	b.WriteString(`You set the asking price for a second-hand item and write its listing.

`)
	b.WriteString("The item: " + in.Item.Name + "\n")
	// Named as absent rather than left blank. "The seller's own words: " with
	// nothing after it reads as a seller who said nothing worth repeating; this
	// says there was no seller input at all, which is the fact the rules below
	// depend on — with no stated words, everything in the listing has to come
	// from the photo or from nowhere.
	if strings.TrimSpace(in.Description) == "" {
		b.WriteString("The seller wrote no description — this run is from a photo alone.\n")
	} else {
		b.WriteString("The seller's own words: " + in.Description + "\n")
	}
	if len(in.Item.KeyAttributes) > 0 {
		b.WriteString("Observed about it: " + strings.Join(in.Item.KeyAttributes, "; ") + "\n")
	}
	if in.MarketName != "" {
		b.WriteString("The market: " + in.MarketName + "\n")
	}

	// The arithmetic, already done. The model is never asked to derive any of
	// this: given a page of prices and asked to justify a figure against them,
	// the previous model produced two wrong numbers in one confident sentence.
	s := in.Stats
	c := s.CurrencySymbol
	b.WriteString(fmt.Sprintf("\nWhat %d comparable listings are asking: lowest %s%d, median %s%d, highest %s%d.\n",
		s.PricedCount, c, s.LowestMinor/100, c, s.MedianMinor/100, c, s.HighestMinor/100))
	if s.LowerQuartile != nil && s.UpperQuartile != nil {
		b.WriteString(fmt.Sprintf("The middle half of them sit between %s%d and %s%d.\n",
			c, *s.LowerQuartile/100, c, *s.UpperQuartile/100))
	}
	if s.SoldCount > 0 {
		b.WriteString(fmt.Sprintf("%d similar items have sold nearby in the last month", s.SoldCount))
		if s.MedianDaysToSell != nil {
			b.WriteString(fmt.Sprintf(", typically within %d days of being listed", *s.MedianDaysToSell))
		}
		b.WriteString(".\n")
	}

	if len(in.Comparables) > 0 {
		b.WriteString("\nThe listings themselves:\n")
		for _, comp := range in.Comparables {
			b.WriteString("- " + comparableLine(comp, c) + "\n")
		}
	}

	b.WriteString(`
Rules:
- These listings are comparable items, NOT the item being priced. Never take the item's identity, brand, model or features from them — they describe other people's things.
- Do not recalculate any of the figures above. They are measured and they are correct; use them as given.
- Price inside the observed range, and normally inside the middle half. Go above the middle only if the item is genuinely better than what is listed, and below only if it is genuinely worse.
- The sold listings show that certain prices WORKED. They cannot show that a price is too high: items that failed to sell are not in the list, so nothing here is evidence against any price.
- The prices are what sellers are ASKING, not what buyers paid. Treat them as the top of the range rather than as settled value.
- The description must only contain facts from the seller's words and what was observed. Do not invent condition, history, smells, pets, or reasons for selling. If the only stated fault is a scratched top, do not write that the rest is in good condition — you do not know that.
- Do not mention prices, the market, comparables, or this analysis in the title or the description. They are a listing, not a report.
- Answer in the same units as the prices above: a whole number, no currency symbol, no decimals.`)

	// The rule above says "the seller's words and what was observed". With no
	// seller, half of that vanishes, and the remaining half is a short list —
	// which is exactly the condition under which a model starts writing the
	// sentences it has seen in a thousand listings. A short honest description
	// is the correct output here, and it has to be asked for, because "write a
	// listing" on its own does not sound like a request for three lines.
	if strings.TrimSpace(in.Description) == "" {
		b.WriteString(`
- There is no seller description on this run, so the observations above are everything that is known. Write only from them. A two-sentence listing that says what the item is and nothing more is the right answer; do not pad it with condition, completeness, history, or how well it works, because none of that was established.`)
	}

	return b.String()
}

func comparableLine(comp Comparable, currency string) string {
	price := "no price"
	if comp.PriceMinor != nil {
		if *comp.PriceMinor == 0 {
			price = "free"
		} else {
			price = fmt.Sprintf("%s%d", currency, *comp.PriceMinor/100)
		}
	}

	line := price + " — " + strings.TrimSpace(comp.Title)
	if comp.IsSold {
		// Marked, because a sold card is evidence of a different kind and the
		// rules above treat it differently.
		line += " (sold"
		if comp.DaysListed != nil {
			line += fmt.Sprintf(", listed %d days before it went", *comp.DaysListed)
		}
		line += ")"
	}
	if comp.City != "" {
		line += " [" + comp.City + "]"
	}
	return line
}
