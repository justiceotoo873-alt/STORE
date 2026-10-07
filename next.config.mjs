/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Keep this newly separate Vercel site rooted in online-store/, not the sibling dashboard.
  outputFileTracingRoot: process.cwd(),
  images: { unoptimized: true },
  headers: async () => [{ source: '/(.*)', headers: [
    { key: 'X-Content-Type-Options', value: 'nosniff' },
    { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
    { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
    { key: 'X-Frame-Options', value: 'DENY' }
  ] }]
};
export default nextConfig;
