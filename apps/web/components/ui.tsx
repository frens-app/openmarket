import Image, { type StaticImageData } from "next/image";
import { SITE } from "@/lib/site";

/** An iPhone-style frame around a real app screenshot. */
export function PhoneFrame({
  src,
  alt,
  priority = false,
  size = "md",
  className = "",
}: {
  src: StaticImageData | string;
  alt: string;
  priority?: boolean;
  /** "sm" is the flanking size in the hero cluster. */
  size?: "sm" | "md";
  className?: string;
}) {
  const width = size === "sm" ? "w-[210px]" : "w-[270px] sm:w-[300px]";
  return (
    <div
      className={`relative mx-auto ${width} overflow-hidden rounded-[2.6rem] border-[6px] border-[#1c1f27] bg-black shadow-[0_30px_80px_-20px_rgba(47,208,138,0.25)] ${className}`}
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
      <h3 className="mb-2 font-display text-[19px] font-bold tracking-tight text-white">
        {title}
      </h3>
      <p className="text-[15px] leading-7 text-gray-400">{children}</p>
    </div>
  );
}

export function SectionHeading({
  eyebrow,
  title,
  align = "center",
  children,
}: {
  eyebrow: string;
  title: string;
  align?: "center" | "left";
  children?: React.ReactNode;
}) {
  const centered = align === "center";
  return (
    <div className={centered ? "mx-auto max-w-2xl text-center" : "max-w-xl"}>
      <Eyebrow>{eyebrow}</Eyebrow>
      <h2 className="mt-3 font-display text-3xl font-bold leading-[1.05] tracking-tight text-white sm:text-4xl">
        {title}
      </h2>
      {children ? (
        <p className="mt-4 text-lg leading-8 text-gray-400">{children}</p>
      ) : null}
    </div>
  );
}

/** Small monospaced kicker above a heading. */
export function Eyebrow({ children }: { children: React.ReactNode }) {
  return (
    <p className="font-mono text-xs uppercase tracking-[0.18em] text-gray-500">
      {children}
    </p>
  );
}

export function DownloadButton({
  children = "Download for iOS",
  variant = "primary",
  href = SITE.downloadUrl,
}: {
  children?: React.ReactNode;
  variant?: "primary" | "ghost";
  href?: string;
}) {
  const base =
    "inline-flex items-center rounded-xl px-7 py-3.5 text-[17px] font-semibold transition";
  return (
    <a
      href={href}
      className={
        variant === "primary"
          ? `${base} bg-accent text-on-accent hover:bg-accent-soft`
          : `${base} border border-white/15 text-white hover:bg-white/5`
      }
    >
      {children}
    </a>
  );
}

/**
 * One of the three things the app is for. Rendered as hairline-separated cells
 * rather than floating cards so the trio reads as one band on a phone.
 */
export function Pillar({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="bg-ink p-7 sm:p-9">
      <h3 className="font-display text-2xl font-bold leading-tight tracking-tight text-white">
        {title}
      </h3>
      <p className="mt-3 leading-7 text-gray-400">{children}</p>
    </div>
  );
}

/** A fact in label/value form — scannable by a reader and by an answer engine. */
export function Spec({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4 px-1 py-3.5 font-mono text-[13px] sm:block sm:px-6 sm:py-5">
      <dt className="uppercase tracking-[0.14em] text-gray-500">{label}</dt>
      <dd className="text-right text-white sm:mt-2 sm:text-left">{value}</dd>
    </div>
  );
}

/** A claim in the alternating detail sections. */
export function Point({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <li className="flex gap-3">
      <span aria-hidden className="font-mono text-sm leading-7 text-accent">
        →
      </span>
      <p className="leading-7 text-gray-400">
        <strong className="font-semibold text-white">{title}</strong>{" "}
        {children}
      </p>
    </li>
  );
}

export function CtaBlock({
  title = "Get Openmarket",
  body = "Search, save, and price-check local listings in seconds.",
}: {
  title?: string;
  body?: string;
}) {
  return (
    <section className="mx-auto max-w-6xl px-5 pb-24">
      <div className="rounded-3xl border border-accent/25 bg-gradient-to-b from-accent/10 to-transparent px-6 py-14 text-center">
        <h2 className="font-display text-3xl font-bold tracking-tight text-white sm:text-4xl">
          {title}
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-lg leading-8 text-gray-400">
          {body}
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-4">
          <DownloadButton />
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
