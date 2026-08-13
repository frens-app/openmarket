import Link from "next/link";
import searchShot from "@/public/screens/search.png";
import filtersShot from "@/public/screens/filters.png";
import homeShot from "@/public/screens/home.png";
import priceCheckShot from "@/public/screens/price-check.png";
import priceResultShot from "@/public/screens/price-result.png";
import travelShot from "@/public/screens/travel-time.png";
import {
  PhoneFrame,
  ShotCard,
  Feature,
  SectionHeading,
  CtaBlock,
  JsonLd,
} from "@/components/ui";
import { SITE } from "@/lib/site";

const FAQ: { q: string; a: string }[] = [
  {
    q: "What is Open Market?",
    a: "Open Market is a free, native iOS app for browsing local Marketplace listings. It adds the things power buyers and sellers wish they had: location filters that actually work, distance and travel time on every listing, instant saves and recently-viewed, a filter that hides listings you've already opened, and a price-check tool that tells sellers what similar items list and sell for nearby.",
  },
  {
    q: "Is Open Market affiliated with Facebook or Meta?",
    a: "No. Open Market is an independent app. You browse Facebook Marketplace listings with your own account, and when you want to message a seller or make an offer, the app hands you to the Facebook app — deals stay where sellers already are.",
  },
  {
    q: "Do I need a Facebook account?",
    a: "Browsing works without one — search, filters, distances, and saves all function. Signing in with your own Facebook account (on Facebook's own login page) unlocks the full experience: endless scrolling past the first page and seller names and ratings.",
  },
  {
    q: "How do I message a seller?",
    a: "Tap \"View on Facebook\" on any listing and it opens that exact listing in the Facebook app, where you can message, save, or make an offer with your own account. Open Market never sends messages for you.",
  },
  {
    q: "Where does my data live?",
    a: "On your phone. Saves, recently viewed, and search history are stored on-device. Your Facebook session stays inside the app's browser and is never sent to Open Market's servers.",
  },
  {
    q: "Is Open Market on Android or the web?",
    a: "Not yet — Open Market is iOS-only for now.",
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
          offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
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
          className="pointer-events-none absolute inset-x-0 top-[-200px] h-[500px] bg-[radial-gradient(ellipse_at_top,rgba(10,132,255,0.18),transparent_60%)]"
        />
        <div className="mx-auto grid max-w-6xl items-center gap-14 px-5 pb-20 pt-16 sm:pt-24 lg:grid-cols-2">
          <div>
            <h1 className="text-4xl font-bold tracking-tight text-white sm:text-6xl">
              Local listings,{" "}
              <span className="text-accent">with superpowers.</span>
            </h1>
            <p className="mt-6 max-w-xl text-lg leading-8 text-gray-300">
              Open Market is a fast, native iOS app for browsing Marketplace
              listings near you. Location filters that actually work. Distance
              and travel time on every listing. Saves that load instantly. And
              for sellers — prices backed by what actually sells nearby.
            </p>
            <div className="mt-9 flex flex-wrap items-center gap-4">
              <a
                href={SITE.downloadUrl}
                className="rounded-full bg-accent px-7 py-3.5 text-[17px] font-semibold text-white transition hover:bg-[#3395ff]"
              >
                Download for iOS
              </a>
              <Link
                href="#buyers"
                className="rounded-full border border-white/15 px-7 py-3.5 text-[17px] font-semibold text-white transition hover:bg-white/5"
              >
                See what it does
              </Link>
            </div>
            <p className="mt-5 text-sm text-gray-500">
              Free · iOS · No sponsored posts, ever
            </p>
          </div>
          <PhoneFrame
            src={searchShot}
            alt="Open Market search results for “desk” showing prices, price drops, and the city and distance on every listing"
            priority
          />
        </div>
      </section>

      {/* Buyer superpowers */}
      <section id="buyers" className="mx-auto max-w-6xl scroll-mt-24 px-5 py-20">
        <SectionHeading eyebrow="For buyers" title="Find it first. Know before you go.">
          Everything on one screen: what it costs, where it is, and how long it
          takes to get there.
        </SectionHeading>
        <div className="mt-14 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <Feature icon="📍" title="Location filters that actually work">
            Pick a place and a radius, and results respect it. Every listing
            card shows its city and real distance from you — no more mystery
            items from two hours away.
          </Feature>
          <Feature icon="🚗" title="Travel time to every listing">
            Walking, driving, and transit estimates on the listing itself, so
            “is it worth the trip” has an answer before you message anyone.
          </Feature>
          <Feature icon="✨" title="Only new listings">
            One toggle hides everything you&apos;ve already opened — a filter
            Marketplace doesn&apos;t have. Stop re-scrolling the same couches.
          </Feature>
          <Feature icon="🔖" title="Saves that are really yours">
            Saved listings live on your phone and load instantly — even offline,
            even if you&apos;re signed out. Your home screen is what you kept.
          </Feature>
          <Feature icon="🕘" title="Recently viewed, always there">
            Every listing you open is kept on-device. Go back to “that desk from
            yesterday” in one tap, with zero loading.
          </Feature>
          <Feature icon="🧹" title="No sponsored posts">
            Sponsored cards are filtered out of every feed. What you see is
            what&apos;s actually for sale near you.
          </Feature>
        </div>

        <div className="mt-16 grid items-center gap-10 lg:grid-cols-2">
          <div className="order-2 lg:order-1">
            <h3 className="text-2xl font-bold tracking-tight text-white">
              Filters you can trust
            </h3>
            <p className="mt-4 text-lg leading-8 text-gray-400">
              Sort by newest, nearest, or price. Set the place and distance
              together. And flip on{" "}
              <strong className="text-white">Only new listings</strong> to hide
              anything you&apos;ve already seen — applied on your device, because
              no marketplace offers it.
            </p>
            <p className="mt-4 text-lg leading-8 text-gray-400">
              Know before you go: every listing carries an honest approximate
              area on the map, plus walking, driving, and transit time from
              where you are.
            </p>
          </div>
          <div className="order-1 space-y-5 lg:order-2">
            <div className="flex justify-center">
              <PhoneFrame
                src={filtersShot}
                alt="Open Market filter sheet with sort options, location with radius, an Only-new-listings toggle, and delivery options"
              />
            </div>
            <ShotCard
              src={travelShot}
              alt="Listing map showing an approximate area and walking, driving, and transit travel times"
              className="mx-auto max-w-[480px]"
            />
          </div>
        </div>
      </section>

      {/* Seller superpowers */}
      <section id="sellers" className="border-y border-white/10 bg-panel">
        <div className="mx-auto max-w-6xl scroll-mt-24 px-5 py-20">
          <SectionHeading eyebrow="For sellers" title="Price it right in 30 seconds.">
            Describe what you&apos;re selling — or just snap a photo — and get an
            asking price backed by what&apos;s listed and what&apos;s actually
            sold near you.
          </SectionHeading>
          <div className="mt-14 grid items-center gap-10 lg:grid-cols-2">
            <div className="flex justify-center gap-5">
              <PhoneFrame
                src={priceCheckShot}
                alt="Open Market Price Check asking “What are you selling?” with photo and text input"
                className="translate-y-6"
              />
              <PhoneFrame
                src={priceResultShot}
                alt="Price Check result recommending a listing price read from nearby and sold listings, with ready-to-paste title and description"
                className="hidden -translate-y-6 sm:block"
              />
            </div>
            <div>
              <ul className="space-y-6 text-lg leading-8 text-gray-400">
                <li>
                  <strong className="block text-white">Real comps, not guesses.</strong>
                  Price Check reads similar listings near you — including ones
                  that just sold — and tells you the number that moves.
                </li>
                <li>
                  <strong className="block text-white">A photo is enough.</strong>
                  Point the camera at the thing. Open Market figures out what it
                  is and runs the search for you.
                </li>
                <li>
                  <strong className="block text-white">Ready-to-paste listing.</strong>
                  Get a title and description you can copy straight into your
                  listing, wherever you post it.
                </li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      {/* How it works / honesty section */}
      <section className="mx-auto max-w-6xl px-5 py-20">
        <SectionHeading eyebrow="How it works" title="Your account. Your phone. Your deals.">
          Open Market is an independent app that works with the marketplace your
          neighborhood already uses.
        </SectionHeading>
        <div className="mt-14 grid gap-5 sm:grid-cols-3">
          <Feature icon="🪪" title="Browse with your own account">
            Sign in on Facebook&apos;s own page, inside the app. Open Market
            never sees your password and works signed-out too.
          </Feature>
          <Feature icon="💬" title="Message in the Facebook app">
            Tap through to the real listing to chat, offer, or pay. Sellers
            never have to leave the platform they already trust.
          </Feature>
          <Feature icon="🔒" title="Everything stays on-device">
            Saves, history, and your session live on your phone — not on our
            servers. There&apos;s nothing to leak and nothing to sell.
          </Feature>
        </div>
        <div className="mt-10 flex justify-center">
          <PhoneFrame
            src={homeShot}
            alt="Open Market home screen with Recently viewed and a Discover feed of listings within 10 miles of San Francisco"
          />
        </div>
      </section>

      {/* FAQ */}
      <section className="mx-auto max-w-3xl px-5 pb-20">
        <SectionHeading eyebrow="FAQ" title="Questions, answered." />
        <div className="mt-10 divide-y divide-white/10 rounded-2xl border border-white/10 bg-card px-6">
          {FAQ.map(({ q, a }) => (
            <details key={q} className="group py-5">
              <summary className="flex cursor-pointer list-none items-center justify-between text-[17px] font-semibold text-white [&::-webkit-details-marker]:hidden">
                {q}
                <span
                  aria-hidden
                  className="ml-4 text-gray-500 transition group-open:rotate-45"
                >
                  +
                </span>
              </summary>
              <p className="mt-3 leading-7 text-gray-400">{a}</p>
            </details>
          ))}
        </div>
      </section>

      <CtaBlock />
    </>
  );
}
