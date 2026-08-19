import type { Metadata } from "next";
import Link from "next/link";
import { CtaBlock, JsonLd, SectionHeading } from "@/components/ui";
import { AUTHORS, SITE, authorSchema } from "@/lib/site";

const AUTHOR = "Brian Li";

export const metadata: Metadata = {
  title: `About ${SITE.name}`,
  description:
    "Who builds Openmarket, and how the guides here are researched — every claim about Facebook Marketplace comes from dated screenshots taken on a real phone.",
  alternates: { canonical: "/about" },
  openGraph: {
    type: "profile",
    title: `About ${SITE.name}`,
    description: "Who builds Openmarket, and how the guides here are researched.",
  },
  twitter: {
    card: "summary_large_image",
    title: `About ${SITE.name}`,
    description: "Who builds Openmarket, and how the guides here are researched.",
  },
};

export default function AboutPage() {
  const author = AUTHORS[AUTHOR];

  return (
    <>
      <JsonLd
        data={{
          "@context": "https://schema.org",
          "@type": "AboutPage",
          url: `${SITE.url}/about`,
          mainEntity: authorSchema(AUTHOR),
          publisher: { "@type": "Organization", name: SITE.name, url: SITE.url },
        }}
      />
      <section className="mx-auto max-w-3xl px-5 pb-10 pt-16">
        <SectionHeading eyebrow="About" title="Who's behind Openmarket">
          A small thing built by someone who uses Marketplace more than he
          probably should.
        </SectionHeading>
      </section>

      <section className="mx-auto max-w-3xl px-5 pb-16">
        <div className="rounded-2xl border border-white/10 bg-card p-8">
          <h2 id={author.slug} className="text-xl font-semibold text-white">
            {AUTHOR}
          </h2>
          <p className="mt-1 text-sm text-gray-500">{author.role}</p>
          <div className="mt-5 space-y-4">
            {author.bio.map((para) => (
              <p key={para.slice(0, 24)} className="leading-7 text-gray-400">
                {para}
              </p>
            ))}
          </div>
          <ul className="mt-6 flex flex-wrap gap-x-5 gap-y-2 text-sm">
            {author.sameAs.map((href) => (
              <li key={href}>
                <a
                  href={href}
                  rel="me noopener"
                  target="_blank"
                  className="text-accent hover:underline"
                >
                  {href.includes("linkedin") ? "LinkedIn" : "X"}
                </a>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section className="mx-auto max-w-3xl px-5 pb-24">
        <h2 className="font-display text-2xl font-bold tracking-tight text-white">
          How the guides here are researched
        </h2>
        <div className="mt-5 space-y-4 leading-7 text-gray-400">
          <p>
            Every factual claim these guides make about Facebook Marketplace is
            either sourced or comes from our own testing, on a stated date and a
            stated app version. Screenshots are taken on a real phone, kept with
            the session details behind them, and re-checked quarterly.
          </p>
          <p>
            Where something could not be measured, it was left out rather than
            estimated. That is why the guides say less than they could — a
            number nobody counted is not worth printing.
          </p>
          <p>
            We are a competitor writing about a competitor, so claims about
            anyone&rsquo;s intentions stay off the page entirely. What is left
            is what can be shown.{" "}
            <Link href="/guides" className="text-accent hover:underline">
              Read the guides
            </Link>
            .
          </p>
        </div>
      </section>
      <CtaBlock />
    </>
  );
}
