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

// Profiles that tie a byline to an identity search engines already know. A bare
// name is a weak entity; a linked one resolves to a person.
export const AUTHORS: Record<string, { sameAs: string[] }> = {
  "Brian Li": {
    sameAs: [
      "https://x.com/brianli101",
      "https://www.linkedin.com/in/brianli101/",
    ],
  },
};
