'use client';
import { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { ArrowLeft, CheckCircle2, Clock3, RefreshCw, ShieldCheck, TriangleAlert } from 'lucide-react';

type State = { order_number: string; reference: string; payment_status: string; order_status: string;
  confirmation_source: 'paystack'|'staff'|'none'; paid_with_paystack: boolean; reservation_expired: boolean; message: string };

export default function PaymentReturn() {
  const search = useSearchParams();
  const ref = search.get('reference') || search.get('trxref') || '';
  const [info, setInfo] = useState<State | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(true);
  const check = useCallback(async () => {
    setBusy(true); setError('');
    try {
      const token = sessionStorage.getItem(`thetieguy-order-${ref}`);
      if (!token || !/^TG[a-f0-9]{32}$/.test(ref)) throw new Error('We cannot check this browser session. Our secure Paystack webhook will still process the payment; keep your reference and contact @thetieguy if you need help.');
      const r = await fetch('/api/payment-status', { method: 'POST', cache: 'no-store',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ reference: ref, token }) });
      const result = await r.json();
      if (!r.ok) throw new Error(typeof result.error === 'string' ? result.error : 'Payment could not be checked.');
      setInfo(result);
    } catch (problem) { setError(problem instanceof Error ? problem.message : 'Payment status could not be checked.'); }
    finally { setBusy(false); }
  }, [ref]);
  useEffect(() => { void check(); }, [check]);
  const confirmed = info?.payment_status === 'confirmed';
  const needsReview = info?.payment_status === 'payment_review' || info?.payment_status === 'refund_needed';
  const verified = info?.paid_with_paystack === true;
  return <div className="return-page"><header><a href="/"><img src="/brand/logo-header.png" alt="THE TIE GUY" /></a></header><main className="return-panel">
    <div className="return-photo"><img src="/images/hero-tie-burgundy.jpg" alt="Burgundy paisley necktie" /><span>THE DETAILS MAKE THE DIFFERENCE</span></div>
    <div className="return-content"><span className="eyebrow gold-text">SECURE CHECKOUT · PAYSTACK</span><div className={`return-icon ${confirmed?'paid':needsReview?'alert':''}`}>{needsReview||error?<TriangleAlert size={30}/>:verified?<CheckCircle2 size={30}/>:<Clock3 size={30}/>}</div>
      <h1>{busy && !info ? 'Checking your payment.' : confirmed ? 'It’s confirmed.' : needsReview ? 'Needs a review.' : verified ? 'Payment received.' : 'Still processing.'}</h1>
      <p>{error || info?.message || 'We’re asking Paystack for the latest status.'}</p>
      {info && <div className="return-details"><span>ORDER <strong>{info.order_number}</strong></span><span>REFERENCE <strong>{info.reference}</strong></span><span>PAYMENT <strong>{confirmed?info.confirmation_source==='paystack'?'Automatically confirmed by Paystack verification':'Confirmed by our team':needsReview?'Manual exception review':verified?'Verified by Paystack · exception review':'Pending verification'}</strong></span></div>}
      {info?.reservation_expired && info.payment_status !== 'confirmed' && <div className="return-warning">Your original stock reservation has ended. A team member will check availability before fulfilling your order or arranging a refund.</div>}
      <div className="return-actions"><a className="button button-dark" href="/"><ArrowLeft size={17}/> Back to store</a><button className="button button-outline" onClick={()=>void check()} disabled={busy}><RefreshCw size={17}/> {busy?'Checking…':'Check again'}</button></div>
      <div className="return-safe"><ShieldCheck size={16}/> Matching charges are independently verified with Paystack and confirmed automatically. Our team manages fulfilment and exceptions. If charged but still pending, do not pay again—keep your reference and contact @thetieguy.</div>
    </div></main><footer>© {new Date().getFullYear()} THE TIE GUY · Ties. Clips. Brooches</footer></div>;
}
