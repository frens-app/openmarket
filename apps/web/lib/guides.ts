export type Guide = {
  slug: string;
  title: string;
  description: string;
  date: string;
  readingMinutes: number;
  /** Rendered inside a .prose-guide container. */
  html: string;
};

export const GUIDES: Guide[] = [
  {
    slug: "facebook-marketplace-location-filter-not-working",
    title:
      "Facebook Marketplace location filter not working? Here's what's actually happening",
    description:
      "Why Marketplace keeps showing listings from 50 miles away even when you set a radius, what the radius control really does, and how to actually search near you.",
    date: "2026-08-12",
    readingMinutes: 6,
    html: `
<p>You set the radius to 10 miles. The first row of results is 40 miles away. You set it again — same thing. You are not imagining it, and you are not doing it wrong.</p>

<h2>The radius is a suggestion, not a rule</h2>
<p>Marketplace's distance control influences ranking more than it limits results. The feed is assembled from what's popular and available in a broad region around the location it inferred for you, and the radius nudges that mix rather than fencing it. Two consequences follow:</p>
<ul>
<li><strong>Faraway listings leak in.</strong> Especially for popular categories, results well outside your radius rank into the feed because they perform well regionally.</li>
<li><strong>The location it uses may not be yours.</strong> Marketplace often keys off the rough location of your network connection, not your actual neighborhood — on a VPN or a corporate network it can be a different city entirely.</li>
</ul>

<h2>What actually helps</h2>
<ol>
<li><strong>Set the place explicitly, not just the radius.</strong> Searching against a named place gives more consistent local results than adjusting distance alone.</li>
<li><strong>Check each listing's stated city before you commit.</strong> The distance shown on the feed can be missing or stale; the listing's own city is the reliable field.</li>
<li><strong>Sort by distance when the option appears.</strong> It surfaces the close-by listings the default ranking buries.</li>
<li><strong>Re-set the location after travel.</strong> If you searched from another city recently, the inferred location can stick.</li>
</ol>

<h2>The shortcut</h2>
<p><a href="/">Open Market</a>, a free iOS app for browsing local listings, was built around exactly this frustration. You set a place and a radius together, results respect them, and every card shows its city and its real distance from you — plus walking, driving, and transit time on the listing itself. If a result is outside your radius, it simply doesn't appear.</p>
`,
  },
  {
    slug: "stop-seeing-same-listings-facebook-marketplace",
    title: "How to stop scrolling past the same listings again and again",
    description:
      "Marketplace has no “hide what I've seen” option, so every session starts with re-reading yesterday's feed. Here are the workarounds — and the one real fix.",
    date: "2026-08-12",
    readingMinutes: 5,
    html: `
<p>Serious buyers check the feed a few times a day, because good deals go in hours. The tax on that habit: every session starts by scrolling past everything you already saw this morning. The same sectional. The same Peloton. The same “vintage” coffee table.</p>

<h2>Why the feed repeats itself</h2>
<p>Marketplace ranks by what it thinks will get engagement, and things you've looked at are evidence of engagement. There is no “only show me new listings” switch, no “sort by newest since my last visit”, and hiding listings one by one is a per-item chore that teaches the ranking very little.</p>

<h2>Workarounds people use</h2>
<ul>
<li><strong>Sort by “Date listed: newest first”</strong> and stop when you recognize a listing. Works, but you lose the relevance ranking entirely, and one re-listed item breaks the “stop when familiar” rule.</li>
<li><strong>Search, don't browse.</strong> Tight queries (“walnut dresser”, not “dresser”) churn less than category feeds.</li>
<li><strong>Save aggressively, then work from saves.</strong> Turns the feed into an inbox — but you still had to scroll the feed to build it.</li>
</ul>

<h2>The real fix: filter on your own history</h2>
<p>Your phone already knows which listings you've opened. A filter that hides them turns a stale feed into a pure stream of new inventory — Marketplace just doesn't offer one.</p>
<p><a href="/">Open Market</a> does. It keeps your viewing history on-device and adds an <strong>“Only new listings”</strong> toggle to its filters: flip it on and anything you've already opened disappears from results. Checking the feed twice a day stops meaning reading it twice.</p>
`,
  },
  {
    slug: "how-to-price-used-items",
    title: "How to price used items so they actually sell",
    description:
      "A practical pricing method for local selling: what percentage of retail to ask, how condition changes the math, and why sold prices beat listed prices.",
    date: "2026-08-12",
    readingMinutes: 7,
    html: `
<p>Most used items that never sell fail at the price, not the product. Here is a method that takes five minutes and survives contact with lowballers.</p>

<h2>Start from sold, not listed</h2>
<p>Listed prices tell you what other sellers <em>hope</em>. Sold prices tell you what buyers <em>pay</em>. A search of your item will show plenty of both — the listings that have sat for six weeks at a fantasy price are data about what doesn't work. Weight anything that sold recently far above anything that's merely listed.</p>

<h2>The percentage-of-retail baseline</h2>
<p>When you can't find good comps, anchor on what the item costs new today (not what you paid):</p>
<ul>
<li><strong>Like new, in demand:</strong> 60–80% of current retail</li>
<li><strong>Good condition, normal wear:</strong> 40–60%</li>
<li><strong>Visible wear, fully functional:</strong> 25–40%</li>
<li><strong>IKEA-tier or heavily worn:</strong> 10–25%, and price to move</li>
</ul>
<p>Electronics depreciate faster than furniture; anything with a battery loses value by the month. Solid wood and name-brand tools hold value better than almost anything else.</p>

<h2>Leave room to negotiate — a little</h2>
<p>Local buyers offer under asking on principle. Price about 10% above the number you actually want, and no more: inflated prices filter out the serious buyers who sort by price, leaving only the lowballers you padded against.</p>

<h2>Signals you priced it wrong</h2>
<ul>
<li><strong>No messages in 48 hours:</strong> too high, or bad photos. Drop 10–15% — a visible price cut also re-ranks you in many feeds.</li>
<li><strong>Five “is this available?” in an hour:</strong> too low. You can't raise the price on people mid-conversation, but you can hold firm and let them compete.</li>
</ul>

<h2>Or let the data do it</h2>
<p><a href="/sellers">Open Market's Price Check</a> runs this method automatically: describe the item or snap a photo, and it reads similar listings <em>and recent sales near you</em>, then recommends an asking price — with a ready-to-paste title and description. It shows how many nearby and sold listings the number came from, so you know it's grounded, not guessed.</p>
`,
  },
  {
    slug: "local-pickup-safety-tips",
    title: "Local pickup, done safely: a checklist for buyers and sellers",
    description:
      "Where to meet, how to handle payment, what to verify before you drive, and the scams to recognize when buying or selling secondhand locally.",
    date: "2026-08-12",
    readingMinutes: 6,
    html: `
<p>Millions of local deals complete without a hitch, and the ones that go wrong mostly break the same few rules. Here is the short list that covers nearly everything.</p>

<h2>Before you drive</h2>
<ul>
<li><strong>Verify the seller has history.</strong> A profile with ratings and years of activity is a different risk than one created last week.</li>
<li><strong>Get specifics in writing:</strong> model numbers, defects, dimensions. “Does it have any issues I should know about?” in chat creates a record.</li>
<li><strong>Know the distance before committing.</strong> A vague “north side” can mean an hour round trip. Check the real travel time — if it's over ~25 minutes, ask for more photos first so the trip can't be wasted.</li>
</ul>

<h2>Choosing where to meet</h2>
<ul>
<li><strong>Small items:</strong> daylight, public, busy. Coffee shops, grocery store lots, or a police-station “safe exchange zone” — many stations offer marked, camera-covered spots exactly for this.</li>
<li><strong>Furniture and appliances:</strong> pickup at the address is normal. Bring a second person, keep the transaction at the door or garage, and share the address and time with someone.</li>
</ul>

<h2>Payment</h2>
<ul>
<li><strong>Cash or an in-person tap payment at handoff.</strong> Nothing in advance — “deposit to hold it” is the single most common local-marketplace scam.</li>
<li><strong>No gift cards, no shipping “agents”, no overpayment refunds.</strong> Each of those phrases ends the conversation.</li>
<li><strong>Sellers of electronics:</strong> power it on together before money changes hands. Buyers: test every function you can.</li>
</ul>

<h2>Trust the messaging platform</h2>
<p>Keep the conversation on the marketplace's own messenger until the deal is done — moving to text or another app early removes the record and the recourse. This is one reason <a href="/">Open Market</a> hands you to the Facebook app to message sellers instead of building its own chat: the conversation, the profile history, and any buyer protections stay where they already exist.</p>
`,
  },
];

export function getGuide(slug: string): Guide | undefined {
  return GUIDES.find((g) => g.slug === slug);
}
