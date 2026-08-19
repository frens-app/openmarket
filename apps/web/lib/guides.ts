export type Guide = {
  slug: string;
  title: string;
  description: string;
  /** Publication date, ISO. */
  date: string;
  /** Date the claims were last checked against the live site, ISO. */
  lastVerified: string;
  readingMinutes: number;
  /**
   * Unsubstantiated or unfinished. Reachable by URL for review, but kept out of
   * the index, the sitemap and llms.txt, and served `noindex`.
   */
  draft?: boolean;
  /** Rendered inside a .prose-guide container. */
  html: string;
};

// Every guide is held to docs/content-standards.md — sourced claims about
// Facebook Marketplace, no assertions of Meta's intent, and the Section 3
// checklist run before publishing.
export const GUIDES: Guide[] = [
  {
    slug: "facebook-marketplace-items-outside-distance-filter",
    title:
      "Why Facebook Marketplace Shows You Items Outside Your Distance Filter",
    description:
      "Shipped listings, sponsored placements, and the default “Suggested” distance setting are not governed by the mile radius you set. What each one looks like on screen, and how to cut them down.",
    date: "2026-08-18",
    lastVerified: "2026-08-18",
    readingMinutes: 6,
    html: `
<p class="dek">Tested on the Facebook iOS app v574.0.0, searching from San Francisco, CA.</p>

<aside class="tldr">
  <p class="tldr-label">TL;DR</p>
  <p>Facebook Marketplace often shows listings far away and outside of your distance filter range because of shipped items, sponsored listings, and results returned under the default "Suggested" distance setting.</p>
</aside>

<p>You might find yourself frustrated by how many far-away or irrelevant listings turn up on Facebook Marketplace. You're not alone in that — it's a common complaint.</p>

<figure>
  <img src="/guides/distance-filter/reddit-feed-far-items.png" alt="An archived r/FacebookMarketplace post from June 2023 asking why Marketplace keeps showing items that are far away despite a 20 km local radius, with 18 points and 17 comments" loading="lazy" />
  <figcaption>u/charcoalritual, <a href="https://www.reddit.com/r/FacebookMarketplace/comments/14j95p4/why_does_marketplace_keep_showing_me_items_that/">r/FacebookMarketplace</a>, 26 June 2023.</figcaption>
</figure>


<h2>At a glance</h2>
<div class="table-scroll">
<table>
<thead>
<tr><th>What appears</th><th>Why your radius doesn't hold it back</th><th>What you can do</th></tr>
</thead>
<tbody>
<tr><td>Shipped listings</td><td>A shipped item has no meaningful location from your side, so a local pickup radius doesn't constrain it</td><td>Filter delivery method to <strong>Local pickup</strong></td></tr>
<tr><td>Sponsored placements</td><td>Paid units take grid positions regardless of filters, as do retail listings sold through partners</td><td>Nothing in Marketplace's own filters</td></tr>
<tr><td>Results under "Suggested"</td><td>The default distance is a setting named "Suggested", not a mileage value. One San Francisco search under it returned a listing 86 miles out</td><td>Set an explicit radius, once per device</td></tr>
</tbody>
</table>
</div>

<h2>Shipped listings aren't bound by your radius</h2>
<p>Marketplace started as local pickup only. Meta later added shipping, and a shipped listing has no meaningful location from your side — the seller's ZIP is incidental — so a local pickup radius doesn't constrain it.</p>
<p>This is the biggest single source of far-away results, and it's most visible on Explore before you've searched anything.</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/explore-shipped.jpg" alt="The Facebook Marketplace Explore grid, every visible listing carrying a shipping badge in its top corner" loading="lazy" /></div>
  <figcaption>Marketplace Explore. A little delivery truck in the corner of a listing indicates a shipped item — here, every cell in view has one.</figcaption>
</figure>

<p>Marketplace also labels distance on Explore itself, and it labels both directions. One grid carried a cell marked <strong>"Farther away"</strong> and another marked <strong>"Nearby"</strong> at the same time.</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/explore-distance-labels.jpg" alt="A Marketplace Explore grid where one listing carries a Farther away badge while another carries a Nearby badge" loading="lazy" /></div>
  <figcaption>One Explore grid, two distance labels.</figcaption>
</figure>

<h2>Sponsored placements aren't sorted by distance</h2>
<p>Paid units take grid positions regardless of your filters. They come in two shapes: a full row of advertising, and single cells shaped exactly like listings, sitting between them and marked only by a small "Ad". These sponsored listings don't get filtered out.</p>

<p>A search for "fitbit air" from San Francisco returned two listings with distances on them — Oakland &middot; 12 mi and San Jose &middot; 47 mi — and then a full row of Amazfit advertising. Scrolling on, two more ads turned up as ordinary-looking cells among four real listings.</p>

<figure>
  <div class="device-pair">
    <div class="device"><img src="/guides/distance-filter/search-ad-unit.jpg" alt="Marketplace search results showing two listings with mileage labels followed by a labelled Amazfit advertisement occupying a full row" loading="lazy" /></div>
    <div class="device"><img src="/guides/distance-filter/search-ad-cells.jpg" alt="Marketplace search results where two single grid cells are RingConn and WHOOP advertisements marked Ad, sitting among listings labelled 2, 4 and 15 miles away" loading="lazy" /></div>
  </div>
  <figcaption>Both from the same search for "fitbit air" in San Francisco. Left: an ad taking a full row. Right: two ads taking single cells — RingConn and WHOOP — among listings from 2, 4 and 15 miles out. The listings carry a distance; the ads carry an "Ad".</figcaption>
</figure>

<p>Not every commercial placement is labelled that way. This one is a retail product opened from inside Marketplace: an eBay badge, a <strong>"Buy now on eBay"</strong> button, an eBay description, and a line in Facebook's own words — "Facebook may receive a commission on this sale." It carries no location because there isn't one to carry, just free shipping from wherever the seller ships from.</p>

<figure>
  <div class="device-pair">
    <div class="device"><img src="/guides/distance-filter/ebay-partner-feed.jpg" alt="The Marketplace Explore grid with a Raven Table Lamp listed at $36, its corner carrying a badge different from the shipping truck on other cells" loading="lazy" /></div>
    <div class="device"><img src="/guides/distance-filter/ebay-partner-listing.jpg" alt="A Facebook Marketplace item page for an eBay listing, showing an eBay badge, a Buy now on eBay button, and a note that Facebook may receive a commission on the sale" loading="lazy" /></div>
  </div>
  <figcaption>Left: the listing sitting in the Explore grid at $36, its corner badge a different icon from the delivery truck on shipped cells. Right: the same lamp opened a minute later — $35.95, free shipping, and no location line anywhere on the page.</figcaption>
</figure>

<!-- NOT CAPTURED. Count sponsored positions across a defined run of consecutive screens; do not estimate. Uncomment when the file exists.
<figure>
  <img src="/guides/distance-filter/sponsored-density.png" alt="A Marketplace results grid with the sponsored cells and banner units marked, showing how many grid positions they occupy" loading="lazy" />
  <figcaption>[N] consecutive screens captured [DATE]. Sponsored cells and banner units occupied [X] of [Y] grid positions ([Z]%).</figcaption>
</figure>
-->

<h2>The default distance isn't a number — it's "Suggested"</h2>
<p>This one surprises most people, and it's the easiest to fix.</p>
<p>Marketplace's default isn't a distance value. It's a setting labeled <strong>"Suggested."</strong> Most people never open the filter panel and reasonably assume they're seeing nearby items.</p>
<p>Here is what that produced. Searching "anthurium" from San Francisco with the distance filter untouched, the first screen of results ran from San Francisco &middot; 1 mi to Rancho Cordova &middot; 86 mi, with Concord &middot; 28 mi in between.</p>
<p>If you've never manually set a radius, you've never had one.</p>

<!-- SCREENSHOT 3 production note: draw a line from the "Suggested" label to the distance labels on the result cells. -->
<figure>
  <div class="device-pair">
    <div class="device"><img src="/guides/distance-filter/suggested-default.jpg" alt="The Marketplace Distance filter sheet with Suggested selected, above preset options of 20, 40, 60 and 100 miles and a custom distance slider" loading="lazy" /></div>
    <div class="device"><img src="/guides/distance-filter/suggested-results.jpg" alt="Marketplace results for anthurium from San Francisco, with listings labelled Rancho Cordova 86 miles, Concord 28 miles and San Francisco 1 mile" loading="lazy" /></div>
  </div>
  <figcaption>Left: the Distance filter, untouched — "Suggested" is what's selected. Right: the results a minute later, running to Rancho Cordova &middot; 86 mi, with Concord &middot; 28 mi and San Francisco &middot; 1 mi in the same grid.</figcaption>
</figure>

<!-- NOT DRAWN. Uncomment when the graphic exists.
<figure>
  <img src="/guides/distance-filter/radius-vs-drive-time.png" alt="A map illustration showing a straight-line radius circle over a metro area with the smaller area actually reachable in a reasonable drive shaded inside it" loading="lazy" />
  <figcaption>A straight-line radius against the area actually reachable in a reasonable trip.</figcaption>
</figure>
-->

<h2>How to reduce it</h2>
<p><strong>Set an explicit radius.</strong> Filter icon → distance field → change from <strong>Suggested</strong> to a specific mileage. Do this once per device and re-check after major app updates.</p>

<!-- NOT CAPTURED. Needs the "after" state; the Suggested frame above is the before half. Uncomment when the file exists.
<figure>
  <img src="/guides/distance-filter/filter-panel.png" alt="The Marketplace filter panel before and after changing the distance field from Suggested to a specific mileage" loading="lazy" />
  <figcaption>The distance field, before and after.</figcaption>
</figure>
-->

<p><strong>Filter to local pickup only.</strong> Same panel, delivery method → <strong>Local pickup</strong>. This excludes shipping-enabled listings at the source. It also drops nearby sellers who happen to offer shipping, so it's blunt — but correct if you want things you can go pick up today.</p>
<p><strong>Set location by ZIP, not city.</strong> Marketplace measures from a point, not from you. A city-center default measures from the middle of the city rather than from where you are, moving your search area before the radius is even applied.</p>

<h2>Questions people ask</h2>
<h3>Why do I see listings from another state when my radius is set to 20 miles?</h3>
<p>Most often they are shipped listings, which a local pickup radius doesn't constrain, or sponsored placements, which take grid positions regardless of your filters. Filtering delivery method to local pickup removes the first group.</p>

<h3>Does Marketplace ignore the distance filter entirely?</h3>
<p>No. The radius constrains local pickup listings. What it doesn't constrain is shipped listings, sponsored units, and — if you've never opened the filter panel — anything at all, because the default setting is "Suggested" rather than a mileage.</p>

<h3>What does "Suggested" actually mean?</h3>
<p>It is the distance filter's default state, and it is not a number. Until you pick a mileage yourself, you do not have a radius set. In one San Francisco search under it, results ran out to 86 miles.</p>

<h3>Why is a listing "8 miles away" a forty-minute drive?</h3>
<p>Distance is measured in a straight line. Water, highway access, and one-bridge crossings are not part of that measurement.</p>

<h3>Does filtering to local pickup hide good listings?</h3>
<p>Yes, some. It also excludes nearby sellers who happen to offer shipping on an item you could collect in person. It's the right trade only when you want things you can go and pick up.</p>

<h2>A shorter version of all of this</h2>
<p>Openmarket shows local listings only. Accurate distance filtering is on by default — no filter panel, no "Suggested," no shipped listings from three states away mixed into your results. No ads.</p>
<p><a href="/">Try Openmarket →</a></p>

<hr />

<p class="fine-print">Openmarket is not affiliated with, endorsed by, or sponsored by Meta Platforms, Inc. Facebook and Facebook Marketplace are trademarks of Meta Platforms, Inc., used here for identification and commentary only.</p>
`,
  },
];

// A guide that reaches the index without a verification date is a Section 3
// checklist failure; fail the build rather than ship one.
for (const g of GUIDES) {
  if (!g.draft && !g.lastVerified) {
    throw new Error(`Guide "${g.slug}" is missing lastVerified`);
  }
}

export const PUBLISHED_GUIDES = GUIDES.filter((g) => !g.draft);

export function getGuide(slug: string): Guide | undefined {
  return GUIDES.find((g) => g.slug === slug);
}
