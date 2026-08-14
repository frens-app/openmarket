import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy",
  description:
    "How Openmarket handles your data: what we collect, what we use it for, and what never leaves your phone.",
  alternates: { canonical: "/privacy" },
};

export default function PrivacyPage() {
  return (
    <article className="prose-guide mx-auto max-w-3xl px-5 py-16">
      <h1 className="text-3xl font-bold tracking-tight text-white">Privacy</h1>
      <p className="mt-2 text-sm text-gray-500">Last updated August 14, 2026</p>
      <h2>The short version</h2>
      <p>
        We collect what we need to run your account, answer a Price Check, and
        understand how the app is used so we can make it better. We do not sell
        your data, show ads, or track you across other apps. Your Facebook
        session stays in the app&apos;s browser on your phone.
      </p>
      <h2>What we collect</h2>
      <ul>
        <li>
          <strong>Your account:</strong> the phone number you sign up with and a
          verification record, used to sign you in.
        </li>
        <li>
          <strong>Your install:</strong> a device identifier, whether you have
          connected Facebook, and — if you enable notifications — the push token
          Apple issues.
        </li>
        <li>
          <strong>Price Check:</strong> the description you type and the photos
          you attach. Photos are sent to our AI provider to identify the item
          and are not stored; we keep the description, the identification, the
          searches it produced, and the resulting price so we can tell a good
          answer from a bad one.
        </li>
        <li>
          <strong>How you use the app:</strong> events like searches you run and
          listings you open, save, or price-check, with the search term and the
          listing&apos;s title, price, and city. This is what tells us which
          searches come back empty and which features earn their place.
        </li>
        <li>
          <strong>Where you are searching:</strong> the city or area and a
          rounded distance. Your precise coordinates are used on your device and
          are not sent to us.
        </li>
      </ul>
      <h2>What stays on your phone</h2>
      <ul>
        <li>
          <strong>Your Facebook session.</strong> It lives in the app&apos;s
          browser on your device and is never transmitted to Openmarket&apos;s
          servers. Listings are loaded with your own account, and messaging
          happens in the Facebook app.
        </li>
        <li>
          Your saved listings, recently-viewed list, and search history are
          stored on the device, so uninstalling the app removes them.
        </li>
        <li>Your precise location, and the photos in your library.</li>
      </ul>
      <h2>Who we share it with</h2>
      <p>
        Service providers who run parts of the app on our behalf: an SMS
        provider for sign-in codes, Apple for push notifications, an analytics
        provider for usage events, and an AI provider for Price Check. They may
        only use it to provide that service. Your phone number is not sent to
        the analytics provider, and neither are your Facebook cookies or your
        precise coordinates. We do not sell your data.
      </p>
      <h2>Your choices</h2>
      <p>
        You can turn notifications off in iOS Settings at any time, and you can
        delete your account from the app — that closes the account, releases
        your phone number, and ends your sessions. To ask what we still hold
        about you, or to have it erased, email us.
      </p>
      <h2>Questions</h2>
      <p>
        Email <a href="mailto:support@frens.lol">support@frens.lol</a>.
      </p>
    </article>
  );
}
