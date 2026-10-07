import { json } from '@/lib/server';
export const dynamic = 'force-dynamic';
export function GET() {
  const ready = Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY
    && process.env.PAYSTACK_SECRET_KEY && process.env.STORE_ORIGIN);
  return json({ checkout_enabled: ready, test_mode: process.env.PAYSTACK_SECRET_KEY?.startsWith('sk_test_') === true });
}
