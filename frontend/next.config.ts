import path from "path";
import type { NextConfig } from "next";
import { fileURLToPath } from "url";

const frontendRoot = path.dirname(fileURLToPath(import.meta.url));

// Public deployments should proxy /api directly to FastAPI. This rewrite
// remains as a fallback for standalone frontend runs.
const INTERNAL_BACKEND_URL = (
  process.env.INTERNAL_BACKEND_URL ||
  process.env.BACKEND_URL ||
  "http://127.0.0.1:8000"
).replace(/\/$/, "");

const nextConfig: NextConfig = {
  output: "standalone",
  outputFileTracingRoot: frontendRoot,
  turbopack: {
    root: frontendRoot,
  },
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `${INTERNAL_BACKEND_URL}/api/:path*`,
      },
    ];
  },
};

export default nextConfig;
