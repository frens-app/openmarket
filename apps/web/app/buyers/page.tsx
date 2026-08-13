import type { Metadata } from "next";
import searchShot from "@/public/screens/search.png";
import filtersShot from "@/public/screens/filters.png";
import travelShot from "@/public/screens/travel-time.png";
import {
  PhoneFrame,
  ShotCard,
  Feature,
  SectionHeading,
  CtaBlock,
} from "@/components/ui";

export const metadata: Metadata = {
  title: "For buyers — search local listings with filters that actually work",
  description:
    "Open Market gives Marketplace buyers superpowers on iOS: a real place-and-radius filter, distance and travel time on every listing, instant saves and recently viewed, and a toggle that hides listings you've already seen.",
  alternates: { canonical: "/buyers" },
};

export default function BuyersPage() {
  return (
    <>
      <section className="mx-auto grid max-w-6xl items-center gap-14 px-5 pb-16 pt-16 lg:grid-cols-2">
        <div>
          <h1 className="text-4xl font-bold tracking-tight text-white sm:text-5xl">
            Buying local, without the scavenger hunt.
          </h1>
          <p className="mt-6 text-lg leading-8 text-gray-300">
            The best deals go to whoever sees them first and shows up first.
            Open Market is built around exactly that: search that respects your
            location, listings that tell you how far away they really are, and a
            feed that never wastes your scroll on things you&apos;ve already
            seen.
          </p>
        </div>
        <PhoneFrame
          src={searchShot}
          alt="Search results with price, price-drop badges, city, and distance on every card"
          priority
        />
      </section>

      <section className="mx-auto max-w-6xl px-5 py-14">
        <SectionHeading eyebrow="The buyer's toolkit" title="Six things buyers get here and nowhere else" />
        <div className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <Feature icon="📍" title="A radius that means it">
            Set “San Francisco · 10 mi” and that is what you get. Place and
            distance travel together, and every card shows its city and real
            distance from you.
          </Feature>
          <Feature icon="🚗" title="Travel time before you commit">
            Walking, driving, and transit time on every listing. A $50 desk 45
            minutes away is not a $50 desk.
          </Feature>
          <Feature icon="✨" title="Hide what you've seen">
            The “Only new listings” toggle removes anything you&apos;ve already
            opened. Check back twice a day and only ever read what&apos;s new.
          </Feature>
          <Feature icon="🔖" title="Instant saves">
            Save from any listing. Saves live on your phone, load in a quarter
            second, and survive sign-outs, dead batteries, and airplane mode.
          </Feature>
          <Feature icon="🕘" title="Recently viewed">
            Every listing you open is kept. That lamp you saw at lunch is one
            tap away at dinner — no re-searching, no loading.
          </Feature>
          <Feature icon="⚡️" title="Native-app fast">
            Listings you&apos;ve opened before appear instantly. The next
            batch is prefetched while you scroll, so tapping a card feels like
            turning a page.
          </Feature>
        </div>
      </section>

      <section className="border-y border-white/10 bg-panel">
        <div className="mx-auto grid max-w-6xl items-center gap-12 px-5 py-16 lg:grid-cols-2">
          <div className="space-y-5">
            <div className="flex justify-center">
              <PhoneFrame
                src={filtersShot}
                alt="Filter sheet: sort, location and radius, only-new-listings toggle, delivery options"
              />
            </div>
            <ShotCard
              src={travelShot}
              alt="Approximate area map with walking, driving, and transit times"
              className="mx-auto max-w-[440px]"
            />
          </div>
          <div>
            <h2 className="text-3xl font-bold tracking-tight text-white">
              Honest maps, honest distances
            </h2>
            <p className="mt-5 text-lg leading-8 text-gray-400">
              Sellers share an approximate area, so Open Market draws an
              approximate area — a circle, not a fake-precise pin. What it adds
              is the number you actually need: how long it takes to get there,
              on foot, by car, or by transit, from where you are right now.
            </p>
            <p className="mt-4 text-lg leading-8 text-gray-400">
              And when a listing is worth it, one tap opens it in the Facebook
              app to message the seller with your own account.
            </p>
          </div>
        </div>
      </section>

      <div className="pt-20">
        <CtaBlock title="Be the buyer who gets there first" />
      </div>
    </>
  );
}
