import type { MetadataRoute } from "next";
import { PUBLISHED_GUIDES } from "@/lib/guides";
import { SITE } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const staticPages = ["", "/buyers", "/sellers", "/guides", "/privacy", "/terms"].map(
    (path) => ({
      url: `${SITE.url}${path}`,
      lastModified: new Date(),
      changeFrequency: "weekly" as const,
      priority: path === "" ? 1 : 0.7,
    }),
  );
  const guidePages = PUBLISHED_GUIDES.map((g) => ({
    url: `${SITE.url}/guides/${g.slug}`,
    lastModified: new Date(g.date),
    changeFrequency: "monthly" as const,
    priority: 0.8,
  }));
  return [...staticPages, ...guidePages];
}
