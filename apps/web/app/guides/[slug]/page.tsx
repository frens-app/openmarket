import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { GUIDES, getGuide } from "@/lib/guides";
import { CtaBlock, JsonLd } from "@/components/ui";
import { authorSchema, SITE } from "@/lib/site";

export function generateStaticParams() {
  return GUIDES.map((g) => ({ slug: g.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const guide = getGuide((await params).slug);
  if (!guide) return {};
  return {
    title: guide.title,
    description: guide.description,
    alternates: { canonical: `/guides/${guide.slug}` },
    robots: guide.draft ? { index: false, follow: false } : undefined,
    openGraph: {
      type: "article",
      title: guide.title,
      description: guide.description,
      publishedTime: guide.date,
      modifiedTime: guide.lastVerified,
      authors: [guide.author],
    },
    // Set explicitly: without these the card inherits the site-wide title and
    // description from the root layout, so a shared article reads as the home
    // page. Images come from the sibling opengraph-image route.
    twitter: {
      card: "summary_large_image",
      title: guide.title,
      description: guide.description,
    },
  };
}

export default async function GuidePage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const guide = getGuide((await params).slug);
  if (!guide) notFound();

  return (
    <>
      <JsonLd
        data={{
          "@context": "https://schema.org",
          "@type": "BlogPosting",
          headline: guide.title,
          description: guide.description,
          datePublished: guide.date,
          dateModified: guide.lastVerified,
          author: authorSchema(guide.author),
          publisher: { "@type": "Organization", name: SITE.name, url: SITE.url },
          mainEntityOfPage: `${SITE.url}/guides/${guide.slug}`,
          image: `${SITE.url}/guides/${guide.slug}/opengraph-image`,
        }}
      />
      {guide.howTo.length > 0 && (
        <JsonLd
          data={{
            "@context": "https://schema.org",
            "@type": "HowTo",
            name: "How to see fewer far-away listings on Facebook Marketplace",
            step: guide.howTo.map((s, i) => ({
              "@type": "HowToStep",
              position: i + 1,
              name: s.name,
              text: s.text,
            })),
          }}
        />
      )}
      {guide.faq.length > 0 && (
        <JsonLd
          data={{
            "@context": "https://schema.org",
            "@type": "FAQPage",
            mainEntity: guide.faq.map(({ q, a }) => ({
              "@type": "Question",
              name: q,
              acceptedAnswer: { "@type": "Answer", text: a },
            })),
          }}
        />
      )}
      <JsonLd
        data={{
          "@context": "https://schema.org",
          "@type": "BreadcrumbList",
          itemListElement: [
            { "@type": "ListItem", position: 1, name: "Guides", item: `${SITE.url}/guides` },
            { "@type": "ListItem", position: 2, name: guide.title, item: `${SITE.url}/guides/${guide.slug}` },
          ],
        }}
      />
      <article className="mx-auto max-w-3xl px-5 pb-20 pt-16">
        <nav aria-label="Breadcrumb" className="mb-8 text-sm text-gray-500">
          <Link href="/guides" className="hover:text-white">
            Guides
          </Link>{" "}
          <span aria-hidden>/</span>
        </nav>
        <h1 className="text-3xl font-bold tracking-tight text-white sm:text-4xl">
          {guide.title}
        </h1>
        <p className="mt-4 text-sm text-gray-500">
          By <span className="text-gray-300">{guide.author}</span> ·{" "}
          <time dateTime={guide.date}>
            {new Date(`${guide.date}T00:00:00`).toLocaleDateString("en-US", {
              year: "numeric",
              month: "long",
              day: "numeric",
            })}
          </time>{" "}
          · {guide.readingMinutes} min read
          {guide.lastVerified && (
            <>
              {" "}
              · Last verified{" "}
              <time dateTime={guide.lastVerified}>{guide.lastVerified}</time>
            </>
          )}
        </p>
        <div
          className="prose-guide mt-10"
          dangerouslySetInnerHTML={{ __html: guide.html }}
        />
        {guide.faq.length > 0 && (
          <section className="mt-14">
            <h2 className="font-display text-2xl font-bold tracking-tight text-white">
              Questions people search for
            </h2>
            <div className="mt-5 divide-y divide-white/10 border-y border-white/10">
              {guide.faq.map(({ q, a }) => (
                <details key={q} className="faq-item group">
                  <summary>{q}</summary>
                  <p>{a}</p>
                </details>
              ))}
            </div>
          </section>
        )}
      </article>
      <CtaBlock />
    </>
  );
}
