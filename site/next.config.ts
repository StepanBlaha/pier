import path from "node:path";
import type { NextConfig } from "next";

// GitHub Pages serves the project site under /pier; locally BASE_PATH is empty.
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

const nextConfig: NextConfig = {
  output: "export",
  basePath,
  trailingSlash: true,
  images: { unoptimized: true },
  // The pier repo sits inside a folder with its own package-lock.json; pin the workspace root.
  turbopack: { root: path.join(__dirname) },
};

export default nextConfig;
