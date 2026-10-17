export type Guide = {
  slug: string;
  title: string;
  description: string;
  /** Publication date, ISO. */
  date: string;
  /** Date the claims were last checked against the live site, ISO. */
  lastVerified: string;
  /** Shown as a byline and emitted as the schema.org Person author. */
  author: string;
  /**
   * Rendered as collapsed accordions at the foot of the article and emitted as
   * FAQPage schema. Phrase each question the way it gets typed into a search
   * box, and answer it in two or three self-contained sentences — the answer
   * has to stand up once it is lifted away from the page.
   */
  faq: { q: string; a: string }[];
  /**
   * HowTo schema for the "How to reduce it" section. Kept in step with that
   * prose by hand; edit both or neither.
   */
  howTo: { name: string; text: string }[];
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
      "Shipped items, sponsored listings, and the default “Suggested” setting aren’t governed by the radius you set. What each looks like on screen, and how to cut them down.",
    date: "2026-08-18",
    lastVerified: "2026-08-18",
    author: "Brian Li",
    faq: [
      {
        q: "Does the Facebook Marketplace distance filter work?",
        a: "It works on the listings it governs, which are local pickup listings from nearby sellers. It does not govern shipped listings or paid placements, and if you have never opened the filter panel it governs nothing at all, because the default is a setting named \"Suggested\" rather than a mileage.",
      },
      {
        q: "Why does Marketplace show items far away?",
        a: "Shipped listings have no meaningful location, so a local pickup radius does not constrain them. Paid placements take grid positions regardless of your filters. And under the default \"Suggested\" setting there is no radius in force at all — in one San Francisco search on 18 August 2026, results ran out to 86 miles.",
      },
      {
        q: "What does \"Suggested\" distance mean on Facebook Marketplace?",
        a: "It is the distance filter's default state, and it is not a number. Until you pick a mileage yourself you do not have a radius set. The presets start at 20 miles, so in a city you want Custom distance and its slider.",
      },
      {
        q: "How do I see only local pickup items on Facebook Marketplace?",
        a: "Open the Delivery filter and choose Local rather than Shipped or All Marketplace. That excludes shipping-enabled listings at the source. It also hides nearby sellers who happen to offer shipping, so it is blunt, but it is the right setting when you want something you can collect today.",
      },
    ],
    howTo: [
      {
        name: "Set an explicit radius",
        text: "Open the filter icon, choose Distance, and pick anything other than Suggested. The presets jump 20, 40, 60 and 100 miles, so in a city use Custom distance and its slider.",
      },
      {
        name: "Filter to local pickup only",
        text: "In the Delivery filter choose Local rather than Shipped or All Marketplace. This excludes shipping-enabled listings at the source.",
      },
      {
        name: "Set your location precisely",
        text: "Set the location filter to your neighborhood rather than your city. Marketplace measures from the point you give it, so a city name measures from the city centre.",
      },
    ],
    readingMinutes: 6,
    html: `
<p class="dek">Tested on the Facebook iOS app v574.0.0, searching from San Francisco, CA.</p>

<aside class="tldr">
  <p class="tldr-label">TL;DR</p>
  <p>Facebook Marketplace often shows listings far away and outside of your distance filter range because of shipped items, sponsored listings, and results returned under the default "Suggested" distance setting. Using the right filters can help but you will still see many non-local listings.</p>
</aside>

<p>You might find yourself frustrated by how many far-away or irrelevant listings turn up on Facebook Marketplace. You're not alone in that — it's a common complaint.</p>

<figure class="narrow">
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
<p>Marketplace started as local pickup only. Facebook later added shipping, which isn't constrained by radius. This is one of the biggest sources of far-away results, and it's most visible on Explore before you've searched anything. Shipped listings are often marked with a delivery truck icon in the corner of the listing.</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/explore-shipped.jpg" alt="The Facebook Marketplace Explore grid, every visible listing carrying a shipping badge in its top corner" loading="lazy" /></div>
  <figcaption>Marketplace Explore. The little delivery truck marks a shipped item — here, every cell has one.</figcaption>
</figure>

<h2>Sponsored placements aren't sorted by distance</h2>
<p>Paid items show up in your results regardless of your filters. They come in two shapes: a full row of advertising, and single cells shaped exactly like listings, sitting between them and marked only by a small "Ad". These sponsored listings don't get filtered out.</p>

<p>A search for "fitbit air" from San Francisco returned two listings with distances on them — Oakland &middot; 12 mi and San Jose &middot; 47 mi — and then a full row of Amazfit advertising. Scrolling on, two more ads turned up as ordinary-looking items among four real listings.</p>

<figure>
  <div class="device-pair">
    <div class="device"><img src="/guides/distance-filter/search-ad-unit.jpg" alt="Marketplace search results showing two listings with mileage labels followed by a labelled Amazfit advertisement occupying a full row" loading="lazy" /></div>
    <div class="device"><img src="/guides/distance-filter/search-ad-cells.jpg" alt="Marketplace search results where two single grid cells are RingConn and WHOOP advertisements marked Ad, sitting among listings labelled 2, 4 and 15 miles away" loading="lazy" /></div>
  </div>
  <figcaption>Same search, a minute apart. Left: an ad as a full row. Right: two as single cells, among listings 2 to 15 miles out.</figcaption>
</figure>

<p>Recently, eBay items have been appearing as normal listings as well. When you click into them, they show <strong>"Buy now on eBay"</strong> button, and a line indicating "Facebook may receive a commission on this sale."</p>

<figure>
  <div class="device-pair">
    <div class="device"><img src="/guides/distance-filter/ebay-partner-feed.jpg" alt="The Marketplace Explore grid with a Raven Table Lamp listed at $36, its corner carrying a badge different from the shipping truck on other cells" loading="lazy" /></div>
    <div class="device"><img src="/guides/distance-filter/ebay-partner-listing.jpg" alt="A Facebook Marketplace item page for an eBay listing, showing an eBay badge, a Buy now on eBay button, and a note that Facebook may receive a commission on the sale" loading="lazy" /></div>
  </div>
  <figcaption>Left: the lamp in the Explore grid at $36, its corner badge unlike the shipped cells'. Right: opened a minute later — free shipping, no location anywhere.</figcaption>
</figure>

<!-- NOT CAPTURED. Count sponsored positions across a defined run of consecutive screens; do not estimate. Uncomment when the file exists.
<figure>
  <img src="/guides/distance-filter/sponsored-density.png" alt="A Marketplace results grid with the sponsored cells and banner units marked, showing how many grid positions they occupy" loading="lazy" />
  <figcaption>[N] consecutive screens captured [DATE]. Sponsored cells and banner units occupied [X] of [Y] grid positions ([Z]%).</figcaption>
</figure>
-->

<h2>The default distance isn't a number — it's "Suggested"</h2>
<p>Marketplace's default isn't a distance value. It's a setting labeled <strong>"Suggested."</strong> Most people never open the filter panel and reasonably assume they're seeing nearby items.</p>
<p>Here is what that produced. Searching "anthurium" from San Francisco with the distance filter untouched, the first screen of results ran from San Francisco &middot; 1 mi to Rancho Cordova &middot; 86 mi, with Concord &middot; 28 mi in between.</p>

<!-- SCREENSHOT 3 production note: draw a line from the "Suggested" label to the distance labels on the result cells. -->
<figure>
  <div class="device-pair">
    <div class="device"><img src="/guides/distance-filter/suggested-default.jpg" alt="The Marketplace Distance filter sheet with Suggested selected, above preset options of 20, 40, 60 and 100 miles and a custom distance slider" loading="lazy" /></div>
    <div class="device"><img src="/guides/distance-filter/suggested-results.jpg" alt="Marketplace results for anthurium from San Francisco, with listings labelled Rancho Cordova 86 miles, Concord 28 miles and San Francisco 1 mile" loading="lazy" /></div>
  </div>
  <figcaption>Left: the Distance filter, untouched. Right: the results a minute later, running to 86 miles.</figcaption>
</figure>

<p>Marketplace Explore also frequently recommends items marked <strong>"Farther away"</strong>.</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/explore-distance-labels.jpg" alt="A Marketplace Explore grid where one listing carries a Farther away badge while another carries a Nearby badge" loading="lazy" /></div>
  <figcaption>Explore feed with items marked "Farther away".</figcaption>
</figure>


<!-- NOT DRAWN. Uncomment when the graphic exists.
<figure>
  <img src="/guides/distance-filter/radius-vs-drive-time.png" alt="A map illustration showing a straight-line radius circle over a metro area with the smaller area actually reachable in a reasonable drive shaded inside it" loading="lazy" />
  <figcaption>A straight-line radius against the area actually reachable in a reasonable trip.</figcaption>
</figure>
-->

<h2>How to reduce it</h2>
<p>For step-by-step help, start with our guide to <a href="/guides/facebook-marketplace-distance-filter-not-working">checking your location pin, choosing local pickup, and setting a custom distance</a>.</p>
<p><strong>Set an explicit radius.</strong> Filter icon → <strong>Distance</strong> → anything other than "Suggested".</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/set-distance.jpg" alt="The Marketplace Distance filter with Custom distance selected and its slider set to 7 miles, the preset options above it unselected" loading="lazy" /></div>
  <figcaption>Custom distance at 7 mi — the only option that promises "listings within this specific distance."</figcaption>
</figure>

<p><strong>Filter to local pickup only.</strong> The <strong>Delivery</strong> filter offers Local, Shipped, and All Marketplace. Picking <strong>Local</strong> excludes shipping-enabled listings at the source.</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/set-delivery.jpg" alt="The Marketplace Delivery filter showing three options, Local, Shipped and All Marketplace, with Local selected" loading="lazy" /></div>
  <figcaption>The Delivery filter, set to Local. "All Marketplace" is the setting that lets shipped listings back in.</figcaption>
</figure>

<p><strong>Set your location precisely.</strong> Marketplace distances can be measured from a city broadly or a specific point. Make sure to update your location filters to your specific neighborhood instead of your city more broadly or results will show relative to the center of your city.</p>

<figure>
  <div class="device"><img src="/guides/distance-filter/set-location.jpg" alt="The Marketplace location picker showing a search field reading San Francisco, California above a map of the city with a pin dropped on it" loading="lazy" /></div>
  <figcaption>The location picker. Everything the radius measures is measured from that pin.</figcaption>
</figure>

<h2>A shorter version of all of this</h2>
<p>Openmarket shows local listings only. Accurate distance filtering is on by default — no filter panel, no "Suggested," no shipped listings from three states away mixed into your results. No ads.</p>
<p><a href="/">Try Openmarket →</a></p>

<aside class="method">
  <p class="method-label">How we researched this</p>
  <p>Everything on this page comes from our own testing, not from summarising what other people have written. On 18 August 2026 we used Facebook Marketplace on an iPhone — app version 574.0.0 — searching from San Francisco, California. We ran the searches named above, browsed Explore, and screenshotted what came back across five sessions.</p>
  <p>Every screenshot here is ours, unedited apart from masking personal details. The Reddit threads are linked so you can read them yourself rather than take our word for it. Where we couldn't measure something, we left it out instead of estimating — which is why this guide says less than it could.</p>
  <p>Marketplace behaves differently by market, account history and app version, so your results may differ from ours. We re-check these findings quarterly.</p>
</aside>

<hr />

<p class="fine-print">Openmarket is not affiliated with, endorsed by, or sponsored by Meta Platforms, Inc. Facebook and Facebook Marketplace are trademarks of Meta Platforms, Inc., used here for identification and commentary only.</p>
`,
  },
  {
    slug: "facebook-marketplace-distance-filter-not-working",
    title: "Facebook Marketplace Distance Filter Not Working? Try This",
    description:
      "Check your location pin, choose local pickup, and set a custom distance. Step-by-step tips for fewer far-away listings, plus why ads can still appear.",
    date: "2026-10-15",
    lastVerified: "2026-08-18",
    author: "Brian Li",
    readingMinutes: 4,
    howTo: [
      {
        name: "Check your location pin",
        text: "From Marketplace search results, tap the location beside the pin icon. Search for the neighborhood or postal code where you want to shop, check the point on the map, and tap Apply. Reopen Location to check the selection.",
      },
      {
        name: "Choose local pickup",
        text: "Open the search filters, choose Delivery, select Local rather than Shipped or All Marketplace, and tap See items. Check for the Local chip above the results.",
      },
      {
        name: "Set a custom distance",
        text: "Open Distance, select Custom distance rather than Suggested, and move the slider to your preferred radius. Return to the results, then reopen Distance to check that Custom distance and the intended mileage are selected.",
      },
    ],
    faq: [
      {
        q: "What should I check first if the Facebook Marketplace distance filter is not working?",
        a: "Start with the location pin and the Delivery filter. Set the location to the area where you want to shop, choose Local for pickup listings, then select a custom distance instead of Suggested. These are settings to check, not a guarantee that the feed will contain only nearby listings.",
      },
      {
        q: "Where is the local pickup filter on Facebook Marketplace?",
        a: "In our August 2026 iPhone screenshots, it is under Delivery and labeled Local. Select Local instead of Shipped or All Marketplace, then tap See items. Labels and available controls may differ by account, region, or app version.",
      },
      {
        q: "Will local pickup and a smaller radius remove sponsored posts?",
        a: "Do not expect these settings to remove ads or sponsored posts. You may still see advertising for products or businesses outside your area. Look for the Ad label before treating a card as a local seller's listing.",
      },
      {
        q: "What if ordinary local listings are still outside my radius?",
        a: "Reopen Location, Delivery, and Distance to check the selected values, then compare an ordinary listing's location with your chosen area. If the mismatch remains, save screenshots of the filters and listing when reporting the problem to Facebook. Our archived testing does not establish a universal fix for that case.",
      },
    ],
    html: `
<aside class="tldr">
  <p class="tldr-label">Try these settings first</p>
  <p>Check your location pin and choose local pickup first, then set a custom distance. You may still see ads and sponsored posts for products or businesses outside your area; these settings are not an ad blocker.</p>
</aside>

<p class="dek">Steps and screenshots from the Facebook iOS app v574.0.0, tested in San Francisco on August 18, 2026. Published October 15, 2026 using those archived captures; controls may differ in your app.</p>

<div class="table-scroll">
<table>
<thead><tr><th>Check</th><th>What to choose</th><th>What to look for afterward</th></tr></thead>
<tbody>
<tr><td>Location</td><td>Your intended pickup area</td><td>The correct location in the picker</td></tr>
<tr><td>Delivery</td><td>Local</td><td>A Local chip above the results</td></tr>
<tr><td>Distance</td><td>Custom distance</td><td>Your chosen mileage in the distance sheet</td></tr>
</tbody>
</table>
</div>

<h2>1. Is your location pin in the right place?</h2>
<p>Check the search location before shrinking the radius. If you want to shop near your neighborhood, start there instead of accepting a city-wide location.</p>
<ol>
  <li>Search for an item in Marketplace. Beside the results heading, tap the location next to the pin icon.</li>
  <li>Search for the neighborhood or postal code where you want to shop, then check the point shown on the map.</li>
  <li>Tap <strong>Apply</strong> to return to the results.</li>
  <li>Reopen <strong>Location</strong> and check the selection before judging the distances on listings.</li>
</ol>
<figure>
  <div class="device"><img src="/guides/distance-filter/set-location.jpg" alt="Facebook Marketplace Location picker with a San Francisco search field, map, and Apply button" loading="lazy" /></div>
  <figcaption>Location picker, August 18, 2026. Check the area on the map, then tap Apply.</figcaption>
</figure>

<h2>2. How do you choose local pickup?</h2>
<p>If you want to collect an item in person, check delivery separately from distance. In the version we tested, the pickup option was called <strong>Local</strong> under <strong>Delivery</strong>.</p>
<ol>
  <li>Open the filters from your Marketplace search results and choose <strong>Delivery</strong>.</li>
  <li>Select <strong>Local</strong> instead of <strong>Shipped</strong> or <strong>All Marketplace</strong>.</li>
  <li>Tap <strong>See items</strong>, then check for the <strong>Local</strong> chip above the results.</li>
</ol>
<p>Use this to narrow your search to pickup listings. It is a separate check from whether the seller is close enough: inspect the listing's location before arranging a pickup.</p>
<figure>
  <div class="device"><img src="/guides/distance-filter/set-delivery.jpg" alt="Marketplace Delivery filter with Local selected, Shipped and All Marketplace unselected, and a See items button" loading="lazy" /></div>
  <figcaption>Delivery filter, August 18, 2026. The option is labeled Local, and the confirmation button is See items.</figcaption>
</figure>

<h2>3. Have you set a custom distance?</h2>
<p>Once the location and delivery method are right, open <strong>Distance</strong>. In our archived test, <strong>Suggested</strong> was selected by default; a search using that setting included a result 86 miles from San Francisco.</p>
<ol>
  <li>Open <strong>Distance</strong> from the search results.</li>
  <li>Select <strong>Custom distance</strong> and move the slider to the radius you want.</li>
  <li>Return to the results, then reopen <strong>Distance</strong> to check that Custom distance and your intended mileage are selected.</li>
</ol>
<figure>
  <div class="device"><img src="/guides/distance-filter/set-distance.jpg" alt="Marketplace Distance filter with Custom distance selected and the slider set to 7 miles" loading="lazy" /></div>
  <figcaption>Custom distance selected at 7 miles, August 18, 2026. Reopen this sheet to check the setting.</figcaption>
</figure>

<h2>Why do ads still appear outside your area?</h2>
<p><strong>You may still see ads and sponsored posts for products or businesses outside your area.</strong> Do not expect local pickup and distance settings to remove advertising from the feed.</p>
<p>In our August captures, ads appeared both as a full row and as individual cards mixed between seller listings. The cards were marked <strong>Ad</strong> and did not carry the mileage labels shown on neighboring local listings. An ad in the grid is not a useful test of whether your pickup radius is set correctly.</p>
<p>For examples of ads, shipped items, and partner listings, see <a href="/guides/facebook-marketplace-items-outside-distance-filter">why Facebook Marketplace shows items outside your distance filter</a>. That guide explains what you are seeing in the feed.</p>

<h2>What if local listings are still too far away?</h2>
<p>Pick an ordinary seller listing with a location label, rather than an ad, and compare it with the area you selected. Recheck Location, Delivery, and Distance in the same search. If the settings are right and the listing is still outside your radius, save screenshots of both the filters and the listing when reporting the issue to Facebook.</p>
<p>These steps help you check the settings you control. Our archived testing does not establish a universal fix for ordinary listings that still fall outside an explicitly selected radius.</p>

<aside class="method">
  <p class="method-label">Sources and testing</p>
  <p>This guide uses our August 18, 2026 captures from Facebook iOS v574.0.0 in San Francisco. The three settings screenshots come from one session searching for “firbit air” with Custom distance set to 7 miles. The Suggested example comes from a separate “anthurium” search; the ad examples come from a “fitbit air” search. These are three sessions from the five-session archive behind our linked explainer.</p>
  <p>We reviewed the archived controls for this guide, rather than running a new October test. The captures show filter selections and examples of results, not a measured before-and-after success rate. They do not establish the geographic targeting of the ads. Availability and labels may differ by market, account, and app version.</p>
</aside>

<h2>Updates and corrections</h2>
<p class="fine-print">October 15, 2026: Published using the August 18 testing archive. No corrections recorded.</p>
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
