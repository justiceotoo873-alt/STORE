// Pure, dependency-injected payment state machine. Production imports it ONLY
// through the server-only reconcile adapter; tests supply fake Paystack/RPCs.
// No browser input, webhook body or AI verdict may set 'confirmed' here.
import { matchesVerifiedPayment, verifiedPaidAt } from './paystack';
import type { PaymentOrder, PaystackData } from './paystack';

export type StorePaymentOrder = PaymentOrder & { payment_status: string };
const states = ['pending','provider_verified','payment_review','confirmed','refund_needed','refunded'] as const;
export type StorePaymentState = typeof states[number];
export type PaymentRpc = (name: 'store_flag_payment_review'|'store_settle_verified_payment_v2', args: Record<string, unknown>) =>
  Promise<{ data: unknown; error: { message: string } | null }>;

function acceptedState(value: unknown): StorePaymentState {
  if (typeof value === 'string' && (states as readonly string[]).includes(value))
    return value as StorePaymentState;
  throw new Error('Store payment RPC returned an unexpected state.');
}

export async function reconcileVerifiedOrder(
  order: StorePaymentOrder,
  secret: string,
  verify: (reference: string) => Promise<PaystackData>,
  rpc: PaymentRpc
): Promise<StorePaymentState> {
  const before = acceptedState(order.payment_status);
  if (before !== 'pending' && before !== 'provider_verified') return before;
  const verified = await verify(order.reference);
  if (verified.status !== 'success') return before;

  if (!matchesVerifiedPayment(verified,order,secret)) {
    // Paystack says a charge succeeded, but it is NOT proof this exact order
    // was fully paid. Flag and release the reservation; no stock changes.
    const flagged = await rpc('store_flag_payment_review',{
      p_reference:order.reference,p_order_id:order.id
    });
    if (flagged.error) throw new Error(flagged.error.message);
    return acceptedState(flagged.data);
  }
  if (typeof verified.amount !== 'number' || !Number.isSafeInteger(verified.amount)
    || typeof verified.customer?.email !== 'string' ||
    (verified.domain !== 'test' && verified.domain !== 'live'))
    throw new Error('Verified Paystack fields have an invalid type.');
  const saved = await rpc('store_settle_verified_payment_v2',{
    p_reference:order.reference,p_order_id:order.id,
    p_amount_minor:verified.amount,p_currency:'GHS',p_email:verified.customer.email,
    p_paid_at:verifiedPaidAt(verified),p_domain:verified.domain
  });
  if (saved.error) throw new Error(saved.error.message);
  return acceptedState(saved.data);
}
