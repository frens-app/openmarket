import Link from "next/link";
import filtersShot from "@/public/screens/filters.png";
import priceEvidenceShot from "@/public/screens/price-evidence.png";
import priceListingShot from "@/public/screens/price-on-listing.png";
import searchShot from "@/public/screens/search.png";
import travelShot from "@/public/screens/travel-time.png";
import {
  CtaBlock,
  DownloadButton,
  JsonLd,
  PhoneFrame,
  Pillar,
  Point,
  SectionHeading,
  ShotCard,
  Spec,
} from "@/components/ui";
import { PUBLISHED_GUIDES } from "@/lib/guides";
import { SITE } from "@/lib/site";

const FEATURES = [
  "Distance radius enforced on your device, so a 5-mile search stays within 5 miles",
  "City and real distance from you on every listing card",
  "Walking, driving, and transit time to every listing",
  "A price comparison on any listing, read from similar nearby and recently sold listings",
  "Price Check: photo or description in, an asking price and a ready-to-paste listing out",
  "Only new listings — a filter that hides anything you have already opened",
  "Sponsored posts filtered out of every feed",
  "Saves and recently viewed, kept on your phone",
];

const FAQ: { q: string; a: string }[] = [
  {
    q: "What is Openmarket?",
    a: "Openmarket is an iOS app — a better way to browse the local listings on Marketplace. It adds filters that work, distance and travel time on every card, saves and recently-viewed, a filter that hides listings you've already opened, and a price comparison on any listing, read from what similar items list and sell for nearby.",
  },
  {
    q: "Where do the listings come from?",
    a: "Openmarket aggregates publicly available local listings, including those posted to Facebook Marketplace — thousands of nearby items. It doesn't run its own marketplace: you see the same listings the source carries, browsed with your own account, and messaging and offers happen in the Facebook app.",
  },
  {
    q: "How is it different from browsing Marketplace directly?",
    a: "Three things Marketplace doesn't do: the distance radius is enforced on your device, so a 5-mile search stays within 5 miles; every card carries its city and real distance from you, and every listing carries walking, driving, and transit time; and any listing can be compared against similar nearby and recently sold listings in one tap. Sponsored posts are filtered out, and one toggle hides listings you've already opened.",
  },
  {
    q: "Is Openmarket affiliated with Facebook or Meta?",
    a: "No. Openmarket is an independent app. You browse Facebook Marketplace listings with your own account, and when you want to message a seller or make an offer, the app hands you to the Facebook app — deals stay where sellers already are.",
  },
  {
    q: "Do I need a Facebook account?",
    a: "Browsing works without one — search, filters, distances, price comparisons, and saves all function. Signing in with your own account, on Facebook's own login page inside the app, unlocks endless scrolling past the first page plus seller names and ratings.",
  },
  {
    q: "How does the price comparison work?",
    a: "Open any listing and Openmarket searches similar items near you — both what's listed right now and what recently sold — then shows where this listing's price falls against them on a range bar: the low ask, the band most sit in, and the high. It also estimates how long similar items take to sell. Tap “See what this is based on” to read the actual comparable listings it used.",
  },
  {
    q: "How do I message a seller?",
    a: "Tap “View on Facebook” on any listing and it opens that exact listing in the Facebook app, where you can message, save, or make an offer with your own account. Openmarket never sends messages for you.",
  },
  {
    q: "Is Openmarket on Android or the web?",
    a: "Not yet — Openmarket is iOS-only for now.",
  },
];

export default function HomePage() {
  return (
    <>
      <JsonLd
        data={{
          "@context": "https://schema.org",
          "@type": "SoftwareApplication",
          name: SITE.name,
          operatingSystem: "iOS",
          applicationCategory: "ShoppingApplication",
          description: SITE.description,
          url: SITE.url,
          featureList: FEATURES,
        }}
      />
      <JsonLd
        data={{
          "@context": "https://schema.org",
          "@type": "FAQPage",
          mainEntity: FAQ.map(({ q, a }) => ({
            "@type": "Question",
            name: q,
            acceptedAnswer: { "@type": "Answer", text: a },
          })),
        }}
      />

      {/* Hero */}
      <section className="relative overflow-hidden">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-x-0 top-[-220px] h-[520px] bg-[radial-gradient(ellipse_at_top,rgba(47,208,138,0.16),transparent_62%)]"
        />
        <div className="mx-auto flex max-w-5xl flex-col items-center px-5 pb-4 pt-16 text-center sm:pt-24">
          <h1 className="max-w-3xl font-display text-[2.75rem] font-bold leading-[0.96] tracking-tight text-white sm:text-7xl">
            Actually local listings.
          </h1>
          <p className="mt-6 max-w-xl text-lg leading-8 text-gray-400 sm:text-xl">
            Thousands of nearby listings. Filters that work. And price
            comparisons backed by what actually sells.
          </p>
          <div className="mt-9 flex flex-wrap items-center justify-center gap-4">
            <DownloadButton />
            <DownloadButton variant="ghost" href="#features">
              See what it does
            </DownloadButton>
          </div>
        </div>

        <div className="mx-auto flex max-w-6xl items-end justify-center gap-4 px-5 pt-14 sm:gap-7">
          <PhoneFrame
            src={filtersShot}
            alt="Openmarket filter sheet: sort options, San Francisco with a radius, and an Only-new-listings toggle"
            size="sm"
            className="hidden shrink-0 lg:block"
          />
          <PhoneFrame
            src={searchShot}
            alt="Openmarket search results for “desk” showing the price, a price drop, and the city and distance on every card"
            className="shrink-0"
            priority
          />
          <PhoneFrame
            src={priceListingShot}
            alt="An Openmarket listing for a $150 Nintendo Switch with a price range bar showing most nearby sellers asking $120 to $200"
            size="sm"
            className="hidden shrink-0 lg:block"
          />
        </div>
      </section>

      {/* The three claims as facts, for readers who skim and engines that quote. */}
      <section className="mx-auto max-w-6xl px-5 pt-16">
        <dl className="divide-y divide-white/10 rounded-2xl border border-white/10 bg-card sm:grid sm:grid-cols-4 sm:divide-x sm:divide-y-0">
          <Spec label="Every card" value="City + distance" />
          <Spec label="Radius" value="Enforced on device" />
          <Spec label="Any listing" value="Price comparison" />
          <Spec label="Sponsored posts" value="Filtered out" />
        </dl>
        <p className="mx-auto mt-6 max-w-2xl text-center leading-7 text-gray-400">
          Openmarket aggregates publicly available local listings, including
          those posted to Facebook Marketplace — thousands of nearby items, in
          one place you can actually search.
        </p>
      </section>

      {/* Three pillars */}
      <section id="features" className="scroll-mt-20 px-5 py-20">
        <div className="mx-auto max-w-6xl overflow-hidden rounded-2xl border border-white/10">
          <div className="grid gap-px bg-white/10 lg:grid-cols-3">
            <Pillar title="Nearby listings">
              Set a place and a radius and they hold. A Marketplace search set to
              5 miles can return listings 60 miles away; here the radius is
              enforced on your device, so anything outside it is cleared out
              before you see it. What&apos;s left carries its city and real
              distance on the card, and walking, driving, and transit time on
              the listing.
            </Pillar>
            <Pillar title="Filters that work">
              Sort by newest, nearest, or price. Narrow by price range,
              condition, and whether it ships or you collect it. Then flip on
              <strong className="font-semibold text-white"> Only new listings</strong>{" "}
              to hide everything you&apos;ve already opened — a filter with no
              counterpart on Marketplace at all. Sponsored posts never appear.
            </Pillar>
            <Pillar title="Price comparisons">
              Any listing can be placed against similar ones near you — the low
              ask, the band most sit in, and the high — with the listings behind
              it one tap away. Buy without guessing; sell at the number that
              moves.
            </Pillar>
          </div>
        </div>
      </section>

      {/* Filters, in detail */}
      <section className="mx-auto max-w-6xl px-5 pb-20">
        <div className="grid items-center gap-12 lg:grid-cols-2">
          <div>
            <SectionHeading
              eyebrow="Search"
              align="left"
              title="Find what you're looking for"
            >
              Intelligent search and powerful filters.
            </SectionHeading>
            <ul className="mt-8 space-y-5">
              <Point title="No sponsored posts.">
                Sponsored cards are filtered out of every feed. What you see is
                what&apos;s actually for sale near you.
              </Point>
              <Point title="Saved and recently viewed.">
                Every listing you open is kept. Back to “that desk from
                yesterday” in one tap.
              </Point>
              <Point title="Advanced filters.">
                Hide things you&apos;ve already seen, and narrow by price,
                condition, and pickup or shipping — then sort by newest,
                nearest, or price.
              </Point>
            </ul>
          </div>
          <div className="space-y-6">
            <PhoneFrame
              src={filtersShot}
              alt="Openmarket filter sheet with sort options, location with radius, an Only-new-listings toggle, and delivery options"
            />
            <ShotCard
              src={travelShot}
              alt="A listing map showing an approximate area with walking, driving, and transit travel times"
              className="mx-auto max-w-[480px]"
            />
          </div>
        </div>
      </section>

      {/* Price comparison */}
      <section className="border-y border-white/10 bg-panel">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <div className="grid items-center gap-12 lg:grid-cols-2">
            <div className="flex justify-center gap-5 lg:order-1">
              <PhoneFrame
                src={priceListingShot}
                alt="“About what others are asking” on a $150 Nintendo Switch listing: a range bar from $55 to $399 with most sellers asking $120 to $200, and a note that similar ones usually sell in about two weeks"
                className="translate-y-6"
              />
              <PhoneFrame
                src={priceEvidenceShot}
                alt="The “What this is based on” screen listing the nearby asking prices and recently sold items behind a comparison, with sale speeds like “Sold within a day”"
                className="hidden -translate-y-6 sm:block"
              />
            </div>
            <div className="lg:order-2">
              <SectionHeading
                eyebrow="Price comparison"
                align="left"
                title="Never wonder what it's worth."
              />
              <ul className="mt-8 space-y-5">
                <Point title="Compare with what&rsquo;s listed.">
                  Where this price sits against every similar item for sale near
                  you right now.
                </Point>
                <Point title="Compare with what&rsquo;s selling.">
                  What recently sold nearby, and how fast it went.
                </Point>
              </ul>
            </div>
          </div>
        </div>
      </section>

      {/* Guides — pillar page linking out to the supporting articles, which is
          the half of internal linking that earns them traffic. */}
      {PUBLISHED_GUIDES.length > 0 && (
        <section className="border-t border-white/10">
          <div className="mx-auto max-w-6xl px-5 py-20">
            <SectionHeading eyebrow="Guides" title="How Marketplace actually behaves.">
              Field notes from our own testing, with the screenshots behind every
              claim.
            </SectionHeading>
            <div
              className={
                PUBLISHED_GUIDES.length === 1
                  ? "mx-auto mt-12 grid max-w-2xl gap-5"
                  : "mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3"
              }
            >
              {PUBLISHED_GUIDES.slice(0, 3).map((g) => (
                <Link
                  key={g.slug}
                  href={`/guides/${g.slug}`}
                  className="group rounded-2xl border border-white/10 bg-card p-7 transition hover:border-accent/40"
                >
                  <p className="mb-2 text-xs uppercase tracking-widest text-gray-500">
                    {g.readingMinutes} min read
                  </p>
                  <h3 className="text-lg font-semibold text-white transition group-hover:text-accent">
                    {g.title}
                  </h3>
                  <p className="mt-2 leading-7 text-gray-400">{g.description}</p>
                </Link>
              ))}
            </div>
            {PUBLISHED_GUIDES.length > 3 && (
              <p className="mt-8 text-center">
                <Link href="/guides" className="text-accent hover:underline">
                  All guides &rarr;
                </Link>
              </p>
            )}
          </div>
        </section>
      )}

      {/* FAQ — answers stay in the markup rather than behind a disclosure, so
          crawlers and answer engines read them without running scripts. */}
      <section id="faq" className="scroll-mt-20 border-t border-white/10 bg-panel">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <h2 className="font-display text-3xl font-bold tracking-tight text-white sm:text-4xl">
            Questions, answered.
          </h2>
          <dl className="mt-10 grid gap-x-14 gap-y-9 sm:grid-cols-2">
            {FAQ.map(({ q, a }) => (
              <div key={q}>
                <dt className="font-semibold text-white">{q}</dt>
                <dd className="mt-2 leading-7 text-gray-400">{a}</dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      <div className="pt-20">
        <CtaBlock />
      </div>
    </>
  );
}
