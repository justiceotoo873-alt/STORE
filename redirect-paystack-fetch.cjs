// TEST PROCESS ONLY: Node preload injected by routes.integration.mjs. It
// reroutes ONLY fake Paystack/Supabase hosts to a loopback test backend.
// Production builds and Vercel never set NODE_OPTIONS to load this module.
const oldFetch = globalThis.fetch.bind(globalThis);
const port = process.env.MOCK_FETCH_STUB_PORT;
if (port) globalThis.fetch = (input, init) => {
  const original = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  const replace = original.startsWith('https://api.paystack.co/')
    ? `http://127.0.0.1:${port}/paystack${original.slice('https://api.paystack.co'.length)}`
    : original.startsWith('https://test-supabase.internal/')
      ? `http://127.0.0.1:${port}/supabase${original.slice('https://test-supabase.internal'.length)}`
      : '';
  if (!replace) return oldFetch(input, init);
  if (typeof input === 'string' || input instanceof URL) return oldFetch(replace, init);
  const request = new Request(input, init);
  return oldFetch(new Request(replace, request));
};
