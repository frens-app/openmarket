import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // `standalone` keeps Railway deploys small; Vercel ignores it and does its
  // own thing, so one config serves both hosts.
  output: process.env.RAILWAY_ENVIRONMENT ? "standalone" : undefined,
};

export default nextConfig;
