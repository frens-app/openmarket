import Image, { type StaticImageData } from "next/image";
import { SITE } from "@/lib/site";

/** An iPhone-style frame around a real app screenshot. */
export function PhoneFrame({
  src,
  alt,
  priority = false,
  className = "",
}: {
  src: StaticImageData | string;
  alt: string;
  priority?: boolean;
  className?: string;
}) {
  return (
    <div
      className={`relative mx-auto w-[270px] overflow-hidden rounded-[2.6rem] border-[6px] border-[#1c1f27] bg-black shadow-[0_30px_80px_-20px_rgba(10,132,255,0.25)] sm:w-[300px] ${className}`}
    >
      <Image
        src={src}
        alt={alt}
        width={1206}
        height={2622}
        priority={priority}
        sizes="300px"
        className="h-auto w-full"
      />
    </div>
  );
}

/** A screenshot cropped to a band (e.g. travel-time card) with rounded card chrome. */
export function ShotCard({
  src,
  alt,
  className = "",
}: {
  src: StaticImageData | string;
  alt: string;
  className?: string;
}) {
  return (
    <div
      className={`overflow-hidden rounded-2xl border border-white/10 bg-card ${className}`}
    >
      <Image src={src} alt={alt} width={1206} height={850} sizes="(min-width: 640px) 480px, 100vw" className="h-auto w-full" />
    </div>
  );
}

export function Feature({
  title,
  children,
  icon,
}: {
  title: string;
  children: React.ReactNode;
  icon: string;
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-card p-6">
      <div aria-hidden className="mb-4 grid h-10 w-10 place-items-center rounded-xl bg-accent/15 text-xl">
        {icon}
      </div>
      <h3 className="mb-2 text-[17px] font-semibold text-white">{title}</h3>
      <p className="text-[15px] leading-7 text-gray-400">{children}</p>
    </div>
  );
}

export function SectionHeading({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children?: React.ReactNode;
}) {
  return (
    <div className="mx-auto max-w-2xl text-center">
      <p className="mb-3 text-sm font-semibold uppercase tracking-widest text-accent">
        {eyebrow}
      </p>
      <h2 className="text-3xl font-bold tracking-tight text-white sm:text-4xl">
        {title}
      </h2>
      {children ? (
        <p className="mt-4 text-lg leading-8 text-gray-400">{children}</p>
      ) : null}
    </div>
  );
}

export function CtaBlock({
  title = "Get Openmarket",
  body = "Free on iOS. Search, save, and price-check local listings in seconds.",
}: {
  title?: string;
  body?: string;
}) {
  return (
    <section className="mx-auto max-w-6xl px-5 pb-24">
      <div className="rounded-3xl border border-white/10 bg-gradient-to-b from-card to-panel px-6 py-14 text-center">
        <h2 className="text-3xl font-bold tracking-tight text-white sm:text-4xl">
          {title}
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-lg leading-8 text-gray-400">
          {body}
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-4">
          <a
            href={SITE.downloadUrl}
            className="rounded-full bg-accent px-7 py-3.5 text-[17px] font-semibold text-white transition hover:bg-[#3395ff]"
          >
            Download for iOS
          </a>
        </div>
      </div>
    </section>
  );
}

/** Server-rendered JSON-LD. */
export function JsonLd({ data }: { data: object }) {
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }}
    />
  );
}
