// Shown when Supabase env vars are missing (fresh clone, no .env.local yet).
export default function SetupNotice() {
  return (
    <main className="mx-auto w-full max-w-md flex-1 px-6 py-20 text-center">
      <h1 className="text-xl font-bold">Almost there</h1>
      <p className="mt-3 text-sm text-stone-600">
        The app isn&apos;t connected to Supabase yet. Copy{" "}
        <code className="rounded bg-stone-100 px-1.5 py-0.5">web/.env.example</code>{" "}
        to{" "}
        <code className="rounded bg-stone-100 px-1.5 py-0.5">web/.env.local</code>{" "}
        and fill in your project URL and anon key, then restart the dev server.
      </p>
    </main>
  );
}
