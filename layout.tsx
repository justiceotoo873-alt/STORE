import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  ...(process.env.STORE_ORIGIN ? { metadataBase: new URL(process.env.STORE_ORIGIN) } : {}),
  title: 'THE TIE GUY | Ties. Clips. Brooches',
  description: 'Explore statement neckties, distinctive tie clips and professional brooches from @thetieguy. Dress for the moment.',
  icons: { icon: '/favicon.png' },
  openGraph: {
    title: 'THE TIE GUY — Make an entrance.',
    description: 'Ties. Clips. Brooches. Discover the details that make the look.',
    images: [{ url: '/images/hero-tie-burgundy.jpg', width: 640, height: 640 }]
  }
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
