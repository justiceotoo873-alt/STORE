import { Suspense } from 'react';
import type { Metadata } from 'next';
import PaymentReturn from '@/components/PaymentReturn';
export const metadata: Metadata = { title: 'Payment review | THE TIE GUY', robots: { index: false, follow: false } };
export default function ReturnPage() {
  return <Suspense fallback={<main className="return-page"><div className="return-panel">Checking your payment…</div></main>}><PaymentReturn /></Suspense>;
}
