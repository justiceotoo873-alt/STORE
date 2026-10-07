import { Suspense } from 'react';
import type { Metadata } from 'next';
import PaymentReturn from '@/components/PaymentReturn';
import { supportWhatsappUrl, whatsappGroupFromEnv } from '@/lib/catalog';

// Read the links at request time so they can be changed in Vercel without a rebuild.
export const dynamic = 'force-dynamic';

export const metadata: Metadata = { title: 'Order confirmation | THE TIE GUY', robots: { index: false, follow: false } };

const SUPPORT_MESSAGE = 'Hi The Tie Guy, I need some help with my order.';

export default function ReturnPage() {
  // Two different destinations on purpose:
  //  - support  → the customer-care chat (floating button + footer + status page)
  //  - community → the WhatsApp group invitation (thank-you page only)
  const support = supportWhatsappUrl(process.env.NEXT_PUBLIC_SUPPORT_WHATSAPP || '233592060208', SUPPORT_MESSAGE);
  const group = whatsappGroupFromEnv();
  return <Suspense fallback={<main className="return-page"><div className="return-panel">Checking your payment…</div></main>}>
    <PaymentReturn whatsappGroup={group} supportWhatsapp={support} />
  </Suspense>;
}
