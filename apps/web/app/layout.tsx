import type { Metadata, Viewport } from "next";
import Image from "next/image";
import Link from "next/link";
import {
  Bricolage_Grotesque,
  IBM_Plex_Mono,
  Instrument_Sans,
} from "next/font/google";
import { Analytics } from "@vercel/analytics/next";
import logo from "@/public/logo.png";
import { SITE, DISCLAIMER } from "@/lib/site";
import "./globals.css";

const display = Bricolage_Grotesque({
  subsets: ["latin"],
  weight: ["600", "700", "800"],
  variable: "--font-bricolage",
  display: "swap",
});

const sans = Instrument_Sans({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-instrument-sans",
  display: "swap",
});

const mono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-plex-mono",
  display: "swap",
});

export const metadata: Metadata = {
  metadataBase: new URL(SITE.url),
  title: {
    default: SITE.title,
    template: `%s · ${SITE.name}`,
  },
  description: SITE.description,
  keywords: [
    "local marketplace app",
    "marketplace app ios",
    "browse local listings",
    "marketplace filters",
    "buy and sell locally",
    "price used items",
    "facebook",
    "marketplace",
    "offerup",
    "letgo",
    "vinted",
    "depop",
  ],
  openGraph: {
    type: "website",
    siteName: SITE.name,
    url: SITE.url,
    title: SITE.title,
    description: SITE.description,
  },
  twitter: {
    card: "summary_large_image",
    title: SITE.title,
    description: SITE.description,
  },
  robots: {
    index: true,
    follow: true,
  },
  alternates: {
    canonical: "./",
  },
  appleWebApp: {
    title: SITE.name,
  },
};

export const viewport: Viewport = {
  themeColor: "#05060a",
  width: "device-width",
  initialScale: 1,
};

function Nav() {
  return (
    <header className="sticky top-0 z-50 border-b border-white/10 bg-ink/80 backdrop-blur-xl">
      <nav
        aria-label="Main"
        className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5"
      >
        <Link
          href="/"
          className="flex items-center gap-2.5 font-display text-[19px] font-bold tracking-tight text-white"
        >
          <Image
            src={logo}
            alt=""
            aria-hidden
            className="h-8 w-8 rounded-lg"
            priority
          />
          Openmarket
        </Link>
        <div className="hidden items-center gap-7 text-[15px] text-gray-300 sm:flex">
          <Link href="/#features" className="transition hover:text-white">
            Features
          </Link>
          <Link href="/guides" className="transition hover:text-white">
            Guides
          </Link>
          <Link href="/#faq" className="transition hover:text-white">
            FAQ
          </Link>
        </div>
        <a
          href={SITE.downloadUrl}
          className="rounded-xl bg-accent px-4 py-2 text-[15px] font-semibold text-on-accent transition hover:bg-accent-soft"
        >
          Download for iOS
        </a>
      </nav>
    </header>
  );
}

function Footer() {
  return (
    <footer className="border-t border-white/10 bg-panel">
      <div className="mx-auto grid max-w-6xl gap-10 px-5 py-14 sm:grid-cols-3">
        <div>
          <p className="font-display text-lg font-bold tracking-tight text-white">
            Openmarket
          </p>
          <p className="mt-2 max-w-xs text-sm leading-6 text-gray-400">
            Thousands of nearby listings. Filters that work. And price
            comparisons backed by what actually sells.
          </p>
        </div>
        <nav aria-label="Footer" className="grid grid-cols-2 gap-8 text-sm sm:col-span-2 sm:grid-cols-3">
          <div>
            <p className="mb-3 font-semibold text-white">Product</p>
            <ul className="space-y-2 text-gray-400">
              <li><Link className="hover:text-white" href="/buyers">For buyers</Link></li>
              <li><Link className="hover:text-white" href="/sellers">For sellers</Link></li>
              <li><a className="hover:text-white" href={SITE.downloadUrl}>Download for iOS</a></li>
            </ul>
          </div>
          <div>
            <p className="mb-3 font-semibold text-white">Guides</p>
            <ul className="space-y-2 text-gray-400">
              <li><Link className="hover:text-white" href="/guides">All guides</Link></li>
            </ul>
          </div>
          <div>
            <p className="mb-3 font-semibold text-white">Legal</p>
            <ul className="space-y-2 text-gray-400">
              <li><Link className="hover:text-white" href="/privacy">Privacy</Link></li>
              <li><Link className="hover:text-white" href="/terms">Terms</Link></li>
            </ul>
          </div>
        </nav>
      </div>
      <div className="border-t border-white/10">
        <div className="mx-auto max-w-6xl px-5 py-6">
          <p className="text-xs leading-5 text-gray-500">{DISCLAIMER}</p>
          <p className="mt-3 text-xs text-gray-600">
            © {new Date().getFullYear()} Openmarket
          </p>
        </div>
      </div>
    </footer>
  );
}

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className={`${display.variable} ${sans.variable} ${mono.variable}`}
    >
      <body className="min-h-screen bg-ink">
        <Nav />
        <main>{children}</main>
        <Footer />
        <Analytics />
      </body>
    </html>
  );
}
