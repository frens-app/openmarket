import type { Metadata, Viewport } from "next";
import Link from "next/link";
import { SITE, DISCLAIMER } from "@/lib/site";
import "./globals.css";

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
        <Link href="/" className="flex items-center gap-2.5 font-semibold tracking-tight text-white">
          <span
            aria-hidden
            className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-[15px] font-bold text-white"
          >
            OM
          </span>
          Open Market
        </Link>
        <div className="hidden items-center gap-7 text-[15px] text-gray-300 sm:flex">
          <Link href="/buyers" className="transition hover:text-white">
            For buyers
          </Link>
          <Link href="/sellers" className="transition hover:text-white">
            For sellers
          </Link>
          <Link href="/guides" className="transition hover:text-white">
            Guides
          </Link>
        </div>
        <a
          href={SITE.testflightUrl}
          className="rounded-full bg-accent px-4 py-2 text-[15px] font-semibold text-white transition hover:bg-[#3395ff]"
        >
          Join the beta
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
          <p className="font-semibold text-white">Open Market</p>
          <p className="mt-2 max-w-xs text-sm leading-6 text-gray-400">
            A fast, native iOS app for browsing local listings — built around
            superpowers for buyers and sellers.
          </p>
        </div>
        <nav aria-label="Footer" className="grid grid-cols-2 gap-8 text-sm sm:col-span-2 sm:grid-cols-3">
          <div>
            <p className="mb-3 font-semibold text-white">Product</p>
            <ul className="space-y-2 text-gray-400">
              <li><Link className="hover:text-white" href="/buyers">For buyers</Link></li>
              <li><Link className="hover:text-white" href="/sellers">For sellers</Link></li>
              <li><a className="hover:text-white" href={SITE.testflightUrl}>Join the beta</a></li>
            </ul>
          </div>
          <div>
            <p className="mb-3 font-semibold text-white">Guides</p>
            <ul className="space-y-2 text-gray-400">
              <li><Link className="hover:text-white" href="/guides">All guides</Link></li>
              <li><Link className="hover:text-white" href="/guides/how-to-price-used-items">Pricing used items</Link></li>
              <li><Link className="hover:text-white" href="/guides/local-pickup-safety-tips">Local pickup safety</Link></li>
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
            © {new Date().getFullYear()} Open Market
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
    <html lang="en">
      <body className="min-h-screen bg-ink">
        <Nav />
        <main>{children}</main>
        <Footer />
      </body>
    </html>
  );
}
