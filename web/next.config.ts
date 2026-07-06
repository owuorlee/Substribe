import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // A stray lockfile in the user home dir makes Next mis-infer the workspace
  // root on this machine; pin it to this app.
  turbopack: { root: __dirname },
};

export default nextConfig;
