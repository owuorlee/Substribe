import Link from "next/link";
import { isSupabaseConfigured, supabaseServer } from "@/lib/supabase/server";

export default async function SiteHeader() {
  let signedIn = false;
  if (isSupabaseConfigured()) {
    const supabase = await supabaseServer();
    const { data } = await supabase.auth.getUser();
    signedIn = Boolean(data.user);
  }

  return (
    <header className="border-b border-stone-200 bg-white">
      <div className="mx-auto flex max-w-3xl items-center justify-between px-6 py-3">
        <Link href="/" className="text-lg font-bold text-brand-strong">
          Substribe
        </Link>
        <nav className="flex items-center gap-4 text-sm font-medium">
          <Link href="/browse" className="text-stone-600 hover:text-brand-strong">
            Browse
          </Link>
          {signedIn ? (
            <>
              <Link
                href="/dashboard"
                className="text-stone-600 hover:text-brand-strong"
              >
                Dashboard
              </Link>
              <form action="/auth/signout" method="post">
                <button
                  type="submit"
                  className="text-stone-500 hover:text-stone-700"
                >
                  Sign out
                </button>
              </form>
            </>
          ) : (
            <Link
              href="/login"
              className="rounded-lg bg-brand px-3.5 py-1.5 font-semibold text-white hover:bg-brand-strong"
            >
              Sign in
            </Link>
          )}
        </nav>
      </div>
    </header>
  );
}
