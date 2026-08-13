import { ImageResponse } from "next/og";

export const runtime = "edge";
export const alt = "Open Market — local listings, with superpowers";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OgImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "80px",
          background: "linear-gradient(135deg, #05060a 60%, #0a2a52 100%)",
          color: "white",
          fontFamily: "sans-serif",
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 20,
            marginBottom: 40,
          }}
        >
          <div
            style={{
              width: 64,
              height: 64,
              borderRadius: 16,
              background: "#0a84ff",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 28,
              fontWeight: 700,
            }}
          >
            OM
          </div>
          <div style={{ fontSize: 36, fontWeight: 600 }}>Open Market</div>
        </div>
        <div style={{ fontSize: 72, fontWeight: 700, lineHeight: 1.1 }}>
          Local listings,
        </div>
        <div
          style={{
            fontSize: 72,
            fontWeight: 700,
            lineHeight: 1.1,
            color: "#0a84ff",
          }}
        >
          with superpowers.
        </div>
        <div style={{ fontSize: 28, color: "#9ca3af", marginTop: 36 }}>
          Filters that work · Real distances · Honest prices · iOS
        </div>
      </div>
    ),
    size,
  );
}
