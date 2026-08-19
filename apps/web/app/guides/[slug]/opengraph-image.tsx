import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { GUIDES, getGuide } from "@/lib/guides";

export const alt = "Openmarket guide";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export function generateStaticParams() {
  return GUIDES.map((g) => ({ slug: g.slug }));
}

export default async function GuideOgImage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const guide = getGuide((await params).slug);
  const logo = await readFile(join(process.cwd(), "public/logo.png"));
  const logoSrc = `data:image/png;base64,${logo.toString("base64")}`;
  const title = guide?.title ?? "Openmarket guides";
  // Long headlines are the norm here, so the type steps down rather than
  // overflowing the card.
  const titleSize = title.length > 78 ? 54 : title.length > 54 ? 62 : 72;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "72px 80px",
          background: "linear-gradient(135deg, #05060a 60%, #0a2a52 100%)",
          color: "white",
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={logoSrc}
            alt=""
            width={52}
            height={52}
            style={{ borderRadius: 13 }}
          />
          <div style={{ fontSize: 30, fontWeight: 600 }}>Openmarket</div>
          <div style={{ fontSize: 24, color: "#2fd08a", marginLeft: 8 }}>
            Guides
          </div>
        </div>
        <div
          style={{
            fontSize: titleSize,
            fontWeight: 700,
            lineHeight: 1.12,
            letterSpacing: -1,
          }}
        >
          {title}
        </div>
        <div style={{ fontSize: 26, color: "#9ca3af" }}>
          {guide
            ? `By ${guide.author} · Last verified ${guide.lastVerified}`
            : "Field notes from our own testing"}
        </div>
      </div>
    ),
    size,
  );
}
