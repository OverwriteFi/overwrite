import type { NextConfig } from "next";
import path from "node:path";

const nextConfig: NextConfig = {
  // The app imports contracts/deployments/<chainId>.json from the repo root, one level up.
  turbopack: { root: path.join(__dirname, "..") },
  outputFileTracingRoot: path.join(__dirname, ".."),
};

export default nextConfig;
