import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { GUIDES, getGuide } from "@/lib/guides";
import { CtaBlock, JsonLd } from "@/components/ui";
import { SITE } from "@/lib/site";

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
    openGraph: {
      type: "article",
      title: guide.title,
      description: guide.description,
      publishedTime: guide.date,
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
          "@type": "Article",
          headline: guide.title,
          description: guide.description,
          datePublished: guide.date,
          author: { "@type": "Organization", name: SITE.name, url: SITE.url },
          publisher: { "@type": "Organization", name: SITE.name, url: SITE.url },
          mainEntityOfPage: `${SITE.url}/guides/${guide.slug}`,
        }}
      />
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
          <time dateTime={guide.date}>
            {new Date(`${guide.date}T00:00:00`).toLocaleDateString("en-US", {
              year: "numeric",
              month: "long",
              day: "numeric",
            })}
          </time>{" "}
          · {guide.readingMinutes} min read
        </p>
        <div
          className="prose-guide mt-10"
          dangerouslySetInnerHTML={{ __html: guide.html }}
        />
      </article>
      <CtaBlock />
    </>
  );
}
