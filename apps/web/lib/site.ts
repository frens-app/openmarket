export const SITE = {
  name: "Openmarket",
  domain: "openmarket.io",
  url: "https://openmarket.io",
  title: "Openmarket — local listings for iOS",
  description:
    "Download Openmarket for iOS. Browse nearby Marketplace listings with distance filters, travel times, and price comparisons based on similar local listings.",
  downloadUrl: "https://apps.apple.com/us/app/openmarket-local-listings/id6799314929",
  appStoreId: "6799314929",
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
    role: "Builder",
    bio: [
      "Brian is an avid Marketplace user who browses it daily even when there's nothing he needs to buy. He has sold a few thousand dollars' worth of things on Facebook Marketplace, mostly variegated houseplants.",
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
