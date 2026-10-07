import 'server-only';
import type { SupabaseClient } from '@supabase/supabase-js';
import { verifyPaystack } from './paystack';
import { reconcileVerifiedOrder } from './payment-flow';
import type { StorePaymentOrder, StorePaymentState } from './payment-flow';

export type { StorePaymentOrder, StorePaymentState } from './payment-flow';

// Signed webhook, private customer return and protected cron all call this ONE
// path: independently verify with Paystack, then commit via atomic SQL RPC.
export async function reconcileStorePayment(client: SupabaseClient, secret: string, order: StorePaymentOrder): Promise<StorePaymentState> {
  return reconcileVerifiedOrder(order,secret,
    (reference)=>verifyPaystack(secret,reference),
    async (name,args)=>await client.rpc(name,args)
  );
}
