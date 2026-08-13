import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy",
  description: "How Open Market handles your data: on-device by default.",
  alternates: { canonical: "/privacy" },
};

export default function PrivacyPage() {
  return (
    <article className="prose-guide mx-auto max-w-3xl px-5 py-16">
      <h1 className="text-3xl font-bold tracking-tight text-white">Privacy</h1>
      <p className="mt-2 text-sm text-gray-500">Last updated August 12, 2026</p>
      <h2>The short version</h2>
      <p>
        Open Market is built to keep your activity on your phone. Saves,
        recently-viewed listings, search history, and your browsing session are
        stored on-device. We do not sell data, show ads, or track you across
        other apps.
      </p>
      <h2>What we store on our servers</h2>
      <ul>
        <li>
          <strong>Your account:</strong> the phone number you sign up with and a
          verification record, used only to sign you in.
        </li>
        <li>
          <strong>Push tokens:</strong> if you enable notifications, the token
          Apple issues for delivering them.
        </li>
      </ul>
      <h2>What stays on your device</h2>
      <ul>
        <li>Saved and recently-viewed listings, and your search history.</li>
        <li>
          Your Facebook session, if you sign in — it lives in the app&apos;s
          browser on your phone and is never transmitted to Open Market&apos;s
          servers.
        </li>
        <li>Your location, used to compute distances and travel times locally.</li>
      </ul>
      <h2>Questions</h2>
      <p>
        Email <a href="mailto:hello@openmarket.so">hello@openmarket.so</a>.
      </p>
    </article>
  );
}
