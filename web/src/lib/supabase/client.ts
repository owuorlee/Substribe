import { createBrowserClient } from "@supabase/ssr";

// Lazy so a missing env only fails at interaction time with a clear message,
// not at build/prerender.
export function supabaseBrowser() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    throw new Error(
      "Supabase is not configured — copy web/.env.example to web/.env.local and fill it in.",
    );
  }
  return createBrowserClient(url, key);
}
