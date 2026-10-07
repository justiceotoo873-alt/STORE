'use client';
import { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { ArrowLeft, CheckCircle2, Clock3, RefreshCw, ShieldCheck, TriangleAlert } from 'lucide-react';
import WhatsAppIcon from './WhatsAppIcon';
import { formatGhs } from '@/lib/catalog';

type State = { order_number: string; reference: string; amount_minor?: number | null; currency?: string | null;
  payment_status: string; order_status: string;
  confirmation_source: 'paystack'|'staff'|'none'; paid_with_paystack: boolean; reservation_expired: boolean; message: string };

const COMMUNITY_BENEFITS = [
  'Exclusive discount codes',
  'New product updates',
  'Special offers',
  'Early access to new drops',
  'Campus promotions',
  'Important store updates',
];

export default function PaymentReturn({ whatsappGroup = null, supportWhatsapp = null }:
  { whatsappGroup?: string | null; supportWhatsapp?: string | null }) {
  const search = useSearchParams();
  const ref = search.get('reference') || search.get('trxref') || '';
  const [info, setInfo] = useState<State | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(true);
  const [inviteHidden, setInviteHidden] = useState(false);

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

  // The thank-you page is reachable ONLY through a confirmed payment status
  // that the server verified with Paystack — never from a URL flag.
  const confirmed = info?.payment_status === 'confirmed';
  const needsReview = info?.payment_status === 'payment_review' || info?.payment_status === 'refund_needed';
  const verified = info?.paid_with_paystack === true;
  const total = typeof info?.amount_minor === 'number' ? formatGhs(info.amount_minor) : null;

  if (confirmed && info) return <div className="thanks-page">
    <main className="thanks-card">
      <span className="eyebrow thanks-eyebrow">PAYMENT SUCCESSFUL</span>
      <div className="thanks-mark"><CheckCircle2 size={34} /></div>
      <h1>Thank you for your order!</h1>
      <p className="thanks-lead">Your payment has been confirmed and your order has been received. Our team will take care of the next steps and reach you about delivery on the details you provided.</p>

      <div className="thanks-order" aria-label="Order confirmation">
        <div className="thanks-order-head"><span>ORDER CONFIRMED</span><CheckCircle2 size={15} /></div>
        <div className="thanks-order-row"><span>Order</span><strong>#{info.order_number}</strong></div>
        {total && <div className="thanks-order-row"><span>Order total</span><strong>{total}</strong></div>}
        <div className="thanks-order-row"><span>Payment</span><strong className="thanks-paid">Confirmed</strong></div>
        <div className="thanks-order-row"><span>Reference</span><strong className="thanks-ref">{info.reference}</strong></div>
      </div>

      {!inviteHidden && <section className="thanks-whatsapp" aria-labelledby="invite-title">
        <small>YOUR ORDER IS CONFIRMED ✓</small>
        <h2 id="invite-title">Join The Tie Guy Community</h2>
        <p className="thanks-invite-lead">Thank you for shopping with <strong>The Tie Guy</strong>. Want first access to what&rsquo;s next? You&rsquo;ve joined the Tie Guy family — here&rsquo;s what our group gets:</p>
        <ul className="thanks-benefits">{COMMUNITY_BENEFITS.map((benefit) => <li key={benefit}><CheckCircle2 size={13} />{benefit}</li>)}</ul>
        {whatsappGroup
          ? <a className="button button-cream thanks-primary" href={whatsappGroup} target="_blank" rel="noopener noreferrer nofollow">Join our WhatsApp group</a>
          : <div className="thanks-empty">The WhatsApp group invite is being set up. Ask us in the store and we&rsquo;ll add you.</div>}
        <button type="button" className="thanks-skip" onClick={() => setInviteHidden(true)}>Skip this invitation</button>
      </section>}

      <div className="thanks-actions">
        <a className="button button-outline thanks-secondary" href="/"><ArrowLeft size={16} /> Continue shopping</a>
        {supportWhatsapp && <a className="thanks-support" href={supportWhatsapp} target="_blank" rel="noopener noreferrer"><WhatsAppIcon size={15} /> Questions about this order? Chat with us</a>}
      </div>
      <p className="thanks-note"><ShieldCheck size={14} /> Verified with Paystack. Keep your reference for any question about this order.</p>
    </main>
    <footer className="thanks-footer">© {new Date().getFullYear()} THE TIE GUY · Ties. Clips. Brooches</footer>
  </div>;

  // Charged, but the charge needs a human decision — never claim success.
  if (needsReview && info) return <div className="return-page"><header><a href="/"><img src="/brand/logo-header.png" alt="THE TIE GUY" /></a></header><main className="return-panel">
    <div className="return-photo"><img src="/images/hero-tie-burgundy.jpg" alt="Burgundy paisley necktie" /><span>THE DETAILS MAKE THE DIFFERENCE</span></div>
    <div className="return-content"><span className="eyebrow gold-text">SECURE CHECKOUT · PAYSTACK</span><div className="return-icon alert"><TriangleAlert size={30} /></div>
      <h1>Needs a review.</h1>
      <p>{info.message}</p>
      <div className="return-details"><span>ORDER <strong>{info.order_number}</strong></span><span>REFERENCE <strong>{info.reference}</strong></span><span>PAYMENT <strong>Manual exception review</strong></span></div>
      <div className="return-actions"><a className="button button-dark" href="/"><ArrowLeft size={17} /> Back to store</a>
        {supportWhatsapp && <a className="button button-outline" href={supportWhatsapp} target="_blank" rel="noopener noreferrer"><WhatsAppIcon size={16} /> Chat with us on WhatsApp</a>}
        <button className="button button-outline" onClick={() => void check()} disabled={busy}><RefreshCw size={17} /> {busy ? 'Checking…' : 'Check again'}</button></div>
      <div className="return-safe"><ShieldCheck size={16} /> Do not pay again. Our team resolves these cases directly in Paystack and will contact you.</div>
    </div></main><footer>© {new Date().getFullYear()} THE TIE GUY · Ties. Clips. Brooches</footer></div>;

  // Failed, cancelled, abandoned or not-yet-verifiable: an honest status page.
  return <div className="return-page"><header><a href="/"><img src="/brand/logo-header.png" alt="THE TIE GUY" /></a></header><main className="return-panel">
    <div className="return-photo"><img src="/images/hero-tie-burgundy.jpg" alt="Burgundy paisley necktie" /><span>THE DETAILS MAKE THE DIFFERENCE</span></div>
    <div className="return-content"><span className="eyebrow gold-text">SECURE CHECKOUT · PAYSTACK</span><div className="return-icon"><Clock3 size={30} /></div>
      <h1>{busy && !info ? 'Checking your payment.' : 'Payment not completed.'}</h1>
      <p>{error && !info ? error : info?.message || 'Your payment could not be confirmed. Please try again or contact us on WhatsApp if you need assistance.'}</p>
      {error && !info && <p className="return-help">Your card or Mobile Money was not charged by us, or the payment is still being processed. Your bag is saved on this device — try again, or message us and we will check the reference for you.</p>}
      {info && <div className="return-details"><span>ORDER <strong>{info.order_number}</strong></span><span>REFERENCE <strong>{info.reference}</strong></span><span>PAYMENT <strong>{verified ? 'Verified by Paystack · pending confirmation' : 'Not confirmed'}</strong></span></div>}
      {info?.reservation_expired && <div className="return-warning">Your original stock reservation has ended. A team member will check availability before fulfilling your order or arranging a refund.</div>}
      <div className="return-actions"><a className="button button-dark" href="/">Try payment again <ArrowLeft size={17} /></a>
        {supportWhatsapp && <a className="button button-outline" href={supportWhatsapp} target="_blank" rel="noopener noreferrer"><WhatsAppIcon size={16} /> Chat with us on WhatsApp</a>}
        <button className="button button-outline" onClick={() => void check()} disabled={busy}><RefreshCw size={17} /> {busy ? 'Checking…' : 'Check again'}</button></div>
      <div className="return-safe"><ShieldCheck size={16} /> You were not charged twice. If your bank shows a pending charge, it clears automatically; if it was charged and this page still says pending, do not pay again — send us the reference on WhatsApp.</div>
    </div></main><footer>© {new Date().getFullYear()} THE TIE GUY · Ties. Clips. Brooches</footer></div>;
}
