import type { Metadata } from "next";
import Link from "next/link";
import { DownloadButton, JsonLd } from "@/components/ui";
import { SITE, authorSchema } from "@/lib/site";

const title = "Openmarket is now live on the App Store";
const description =
  "Openmarket is available for iOS. Find nearby Marketplace listings with distance filters, travel times, and local price comparisons.";
const published = "2026-10-10";

export const metadata: Metadata = {
  title,
  description,
  alternates: { canonical: "/launch" },
  openGraph: {
    type: "article",
    title,
    description,
    url: `${SITE.url}/launch`,
    publishedTime: published,
    authors: [`${SITE.url}/about`],
    images: [{ url: "/opengraph-image", width: 1200, height: 630 }],
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
    images: ["/opengraph-image"],
  },
};

export default function LaunchPage() {
  return (
    <>
      <JsonLd
        data={{
          "@context": "https://schema.org",
          "@type": "BlogPosting",
          headline: title,
          description,
          datePublished: published,
          dateModified: published,
          mainEntityOfPage: `${SITE.url}/launch`,
          image: `${SITE.url}/opengraph-image`,
          author: authorSchema("Brian Li"),
          publisher: { "@type": "Organization", name: SITE.name, url: SITE.url },
        }}
      />
      <article className="mx-auto max-w-3xl px-5 py-16 sm:py-24">
        <p className="font-mono text-xs uppercase tracking-widest text-accent">
          Launch · <time dateTime={published}>October 10, 2026</time>
        </p>
        <h1 className="mt-5 font-display text-4xl font-bold leading-tight tracking-tight text-white sm:text-6xl">
          {title}
        </h1>
        <p className="mt-5 text-sm text-gray-400">
          By <Link href="/about#brian-li" className="text-accent hover:underline">Brian Li</Link>
        </p>
        <p className="mt-8 text-xl leading-8 text-gray-300">
          Openmarket is now available to download for iOS. A better way to browse
          local listings is one App Store visit away.
        </p>
        <div className="mt-8"><DownloadButton /></div>
        <div className="mt-12 space-y-6 text-lg leading-8 text-gray-400">
          <p>
            I browse Marketplace every day, even when I&apos;m not looking for
            anything in particular. Openmarket grew out of wanting that browsing
            to feel more local, easier to filter, and easier to make sense of.
          </p>
          <h2 className="font-display text-2xl font-bold text-white">Find things that are actually nearby</h2>
          <p>
            Pick a location and a radius. Openmarket enforces that radius on your
            phone and shows the city and distance on every listing card. Open a
            listing to see walking, driving, and transit times before planning a pickup.
          </p>
          <h2 className="font-display text-2xl font-bold text-white">Make the feed yours</h2>
          <p>
            Sort by newest, nearest, or price. Filter by condition, price range,
            and pickup or shipping. Hide listings you&apos;ve already opened with
            Only new listings, and return to your saves and recently viewed items.
          </p>
          <h2 className="font-display text-2xl font-bold text-white">Get context for the asking price</h2>
          <p>
            Compare a listing with similar nearby items, including listings that
            recently sold. You can inspect the comparable listings behind the
            comparison. These are asking prices, not confirmed final sale prices.
            Selling something? Price Check turns a photo or description into a
            suggested asking price and a listing draft.
          </p>
          <h2 className="font-display text-2xl font-bold text-white">Start browsing</h2>
          <p>
            Download Openmarket from the App Store, choose your location, and
            explore. Openmarket is an independent app; messages and offers happen
            in Facebook, where the original listings live.
          </p>
          <p>
            Learn more about <Link href="/buyers" className="text-accent hover:underline">buying</Link>
            {" "}or <Link href="/sellers" className="text-accent hover:underline">selling</Link>
            {" "}with Openmarket.
          </p>
        </div>
        <div className="mt-10"><DownloadButton /></div>
      </article>
    </>
  );
}
