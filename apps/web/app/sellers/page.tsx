import type { Metadata } from "next";
import priceCheckShot from "@/public/screens/price-check.png";
import priceResultShot from "@/public/screens/price-result.png";
import { PhoneFrame, Feature, SectionHeading, CtaBlock, JsonLd } from "@/components/ui";

export const metadata: Metadata = {
  title: "For sellers — price used items with real local data",
  description:
    "Open Market's Price Check tells you what to ask for anything you're selling: describe it or photograph it, and get a price backed by similar listings and recent sales near you, plus a ready-to-paste title and description.",
  alternates: { canonical: "/sellers" },
};

const FAQ = [
  {
    q: "How does Price Check decide a price?",
    a: "It searches listings similar to yours near your location, weighs what's currently listed against what has recently sold, and recommends the asking price the local market supports. It shows its work — you see how many nearby and sold listings the number was read from.",
  },
  {
    q: "Can I price something from just a photo?",
    a: "Yes. Take or choose a photo and Open Market identifies the item and runs the search. Adding a sentence about condition or model makes the answer sharper.",
  },
  {
    q: "Does Open Market post the listing for me?",
    a: "No — you stay in control. It gives you the price, a ready-to-paste title, and a description; you post them with your own account wherever you sell.",
  },
];

export default function SellersPage() {
  return (
    <>
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
      <section className="mx-auto grid max-w-6xl items-center gap-14 px-5 pb-16 pt-16 lg:grid-cols-2">
        <div>
          <h1 className="text-4xl font-bold tracking-tight text-white sm:text-5xl">
            Stop guessing what your stuff is worth.
          </h1>
          <p className="mt-6 text-lg leading-8 text-gray-300">
            Price too high and it sits for weeks. Price too low and you gave
            away fifty bucks. Open Market&apos;s Price Check reads the local
            market for you — what similar things are listed for{" "}
            <em>and what actually sold</em> — and hands you a number you can
            defend when the lowballers arrive.
          </p>
        </div>
        <div className="flex justify-center gap-5">
          <PhoneFrame
            src={priceCheckShot}
            alt="Price Check input: describe what you're selling or add a photo"
            priority
            className="translate-y-4"
          />
          <PhoneFrame
            src={priceResultShot}
            alt="Price Check result with recommended price and ready-to-paste title and description"
            className="hidden -translate-y-4 sm:block"
          />
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-5 py-14">
        <SectionHeading eyebrow="The seller's toolkit" title="From closet to listed in a minute" />
        <div className="mt-12 grid gap-5 sm:grid-cols-3">
          <Feature icon="📸" title="Photo in, price out">
            A photo or a sentence is enough — both is better. No category
            trees, no forms.
          </Feature>
          <Feature icon="📊" title="Backed by sold data">
            The recommendation is read from real nearby listings and recent
            sales, and it tells you exactly how many of each.
          </Feature>
          <Feature icon="📋" title="Ready-to-paste listing">
            Copy the generated title and description straight into your
            listing. Post it with your own account, keep every dollar.
          </Feature>
        </div>
      </section>

      <section className="mx-auto max-w-3xl px-5 pb-20">
        <SectionHeading eyebrow="FAQ" title="Seller questions" />
        <div className="mt-10 divide-y divide-white/10 rounded-2xl border border-white/10 bg-card px-6">
          {FAQ.map(({ q, a }) => (
            <details key={q} className="group py-5">
              <summary className="flex cursor-pointer list-none items-center justify-between text-[17px] font-semibold text-white [&::-webkit-details-marker]:hidden">
                {q}
                <span aria-hidden className="ml-4 text-gray-500 transition group-open:rotate-45">+</span>
              </summary>
              <p className="mt-3 leading-7 text-gray-400">{a}</p>
            </details>
          ))}
        </div>
      </section>

      <CtaBlock title="Price your next listing with real data" />
    </>
  );
}
