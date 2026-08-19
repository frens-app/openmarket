export const SITE = {
  name: "Openmarket",
  domain: "openmarket.io",
  url: "https://openmarket.io",
  title: "Openmarket — actually local listings",
  description:
    "A better way to marketplace: actually local listings with distance and travel time on every card, filters that work, and price comparisons backed by what actually sells nearby.",
  // TestFlight until the App Store listing is live — swap for the real
  // https://apps.apple.com/... URL then.
  downloadUrl: "https://testflight.apple.com/join/qcB76WmM",
  twitter: undefined as string | undefined,
} as const;

export const DISCLAIMER =
  "Openmarket is an independent app. It is not affiliated with, endorsed by, or sponsored by Meta Platforms, Inc. Facebook and Marketplace are trademarks of Meta Platforms, Inc. Listings are viewed with your own account and messaging happens in the Facebook app.";

// One entry per byline. The /about page and every article's author schema read
// from here and share an @id, so the name resolves to a single entity rather
// than repeating as an unlinked string.
export const AUTHORS: Record<
  string,
  { slug: string; role: string; bio: string[]; sameAs: string[] }
> = {
  "Brian Li": {
    slug: "brian-li",
    role: "Founder, Openmarket",
    bio: [
      "Brian Li builds Openmarket. He has sold a few thousand dollars' worth of things on Facebook Marketplace, mostly variegated houseplants, and he browses it daily even when there is nothing he wants to buy.",
      "That is where the app came from. The listings on Marketplace are good; the browsing is not. Openmarket keeps the listings and fixes the part around them — a radius that holds, real distance and travel time on every card, and no ads.",
      "He writes the guides here too. Every claim they make about Marketplace comes from screenshots taken on his own phone, dated and kept, so anything stated can be checked rather than taken on trust.",
    ],
    sameAs: [
      "https://x.com/brianli101",
      "https://www.linkedin.com/in/brianli101/",
    ],
  },
};

/** Schema identity for a byline, shared by /about and every article. */
export function authorSchema(name: string) {
  const a = AUTHORS[name];
  if (!a) return { "@type": "Person" as const, name };
  return {
    "@type": "Person" as const,
    "@id": `${SITE.url}/about#${a.slug}`,
    name,
    jobTitle: a.role,
    url: `${SITE.url}/about`,
    sameAs: a.sameAs,
  };
}
