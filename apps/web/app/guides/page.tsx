import type { Metadata } from "next";
import Link from "next/link";
import { GUIDES, PUBLISHED_GUIDES } from "@/lib/guides";
import { SectionHeading, CtaBlock } from "@/components/ui";

export const metadata: Metadata = {
  title: "Guides for buying and selling locally",
  description:
    "Practical guides to buying and selling secondhand locally.",
  alternates: { canonical: "/guides" },
};

export default function GuidesIndex() {
  // Drafts are listed locally so an unfinished guide is reachable while it is
  // written. `next build` sets this to "production", so they never ship.
  const listed =
    process.env.NODE_ENV === "development" ? GUIDES : PUBLISHED_GUIDES;

  return (
    <>
      <section className="mx-auto max-w-6xl px-5 pb-10 pt-16">
        <SectionHeading eyebrow="Guides" title="Get better at buying and selling locally">
          Field notes from people who buy and sell secondhand every week — no
          fluff, no listicle padding.
        </SectionHeading>
      </section>
      <section className="mx-auto max-w-4xl px-5 pb-24">
        {listed.length === 0 ? (
          <p className="text-gray-400">New guides are on the way.</p>
        ) : (
        <div className="grid gap-5">
          {listed.map((g) => (
            <Link
              key={g.slug}
              href={`/guides/${g.slug}`}
              className="group rounded-2xl border border-white/10 bg-card p-7 transition hover:border-accent/40"
            >
              <p className="mb-2 text-xs uppercase tracking-widest text-gray-500">
                {g.draft && <span className="text-accent">Draft · </span>}
                {g.readingMinutes} min read
              </p>
              <h2 className="text-xl font-semibold text-white transition group-hover:text-accent">
                {g.title}
              </h2>
              <p className="mt-2 leading-7 text-gray-400">{g.description}</p>
            </Link>
          ))}
        </div>
        )}
      </section>
      <CtaBlock />
    </>
  );
}
