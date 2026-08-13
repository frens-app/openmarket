import type { Metadata } from "next";
import { DISCLAIMER } from "@/lib/site";

export const metadata: Metadata = {
  title: "Terms",
  description: "Terms of use for the Openmarket app and website.",
  alternates: { canonical: "/terms" },
};

export default function TermsPage() {
  return (
    <article className="prose-guide mx-auto max-w-3xl px-5 py-16">
      <h1 className="text-3xl font-bold tracking-tight text-white">Terms of Use</h1>
      <p className="mt-2 text-sm text-gray-500">Last updated August 12, 2026</p>
      <h2>The service</h2>
      <p>
        Openmarket is a browsing tool. Listings, seller profiles, messaging,
        and transactions belong to the platforms where they live; Openmarket
        does not host listings, process payments, or participate in
        transactions. Price Check recommendations are informational, not offers
        or appraisals.
      </p>
      <h2>Your account and conduct</h2>
      <p>
        You sign in with a phone number you control. You agree to use the app
        with your own accounts, for personal, non-commercial browsing, and in
        compliance with the terms of any platform you access through it.
      </p>
      <h2>No warranty</h2>
      <p>
        The app is provided as-is. Listing data originates from third parties
        and can be incomplete, stale, or wrong; verify anything that matters —
        price, condition, availability, meeting details — before acting on it.
      </p>
      <h2>Affiliation</h2>
      <p>{DISCLAIMER}</p>
      <h2>Contact</h2>
      <p>
        Email <a href="mailto:hello@openmarket.so">hello@openmarket.so</a>.
      </p>
    </article>
  );
}
