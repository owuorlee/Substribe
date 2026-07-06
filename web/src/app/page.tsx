// Landing v0 — trust-first, mobile-first. Real flows land behind this page;
// its one job is: "this is legit, and here is exactly how your money is safe."

const steps = [
  {
    title: "Find a seat",
    body: "Browse family plans with open seats — Spotify to start, more coming.",
  },
  {
    title: "Pay with M-Pesa",
    body: "One STK prompt. Your money goes into escrow — not to the owner.",
  },
  {
    title: "Get your invite",
    body: "The plan owner adds your email. Your own login, never a shared password.",
  },
  {
    title: "Money moves when it works",
    body: "Only after you confirm access does the owner get paid. Problem? Instant refund.",
  },
];

const promises = [
  "Escrow on every shilling",
  "No password sharing, ever",
  "Refund if your seat dies",
  "Transparent fees",
];

export default function Home() {
  return (
    <main className="flex-1">
      {/* Hero */}
      <section className="bg-brand-strong text-white">
        <div className="mx-auto max-w-3xl px-6 pt-14 pb-16 sm:pt-20 sm:pb-24">
          <p className="text-sm font-semibold uppercase tracking-widest text-emerald-300">
            Substribe
          </p>
          <h1 className="mt-4 text-4xl font-bold leading-tight sm:text-5xl">
            Premium subscriptions,{" "}
            <span className="text-emerald-300">split fairly.</span>
          </h1>
          <p className="mt-4 max-w-xl text-lg text-emerald-50/90">
            Join a Spotify Premium family seat for{" "}
            <span className="font-semibold text-white">KSh 250/month</span>{" "}
            instead of KSh 599. Pay with M-Pesa. Your money is held safely
            until your seat works — that&apos;s the whole point of us.
          </p>
          <div className="mt-8 flex flex-col gap-3 sm:flex-row">
            <a
              href="/browse"
              className="rounded-xl bg-white px-6 py-3.5 text-center font-semibold text-brand-strong shadow-lg transition hover:bg-emerald-50"
            >
              Browse open seats
            </a>
            <a
              href="#how"
              className="rounded-xl border border-emerald-400/40 px-6 py-3.5 text-center font-semibold text-emerald-100 transition hover:bg-white/5"
            >
              How it works
            </a>
          </div>
          <ul className="mt-10 flex flex-wrap gap-x-5 gap-y-2 text-sm text-emerald-200">
            {promises.map((p) => (
              <li key={p} className="flex items-center gap-1.5">
                <span aria-hidden className="text-emerald-300">
                  ✓
                </span>
                {p}
              </li>
            ))}
          </ul>
        </div>
      </section>

      {/* How it works */}
      <section id="how" className="mx-auto max-w-3xl px-6 py-14 sm:py-20">
        <h2 className="text-2xl font-bold sm:text-3xl">
          Built so nobody gets burned
        </h2>
        <p className="mt-2 max-w-xl text-stone-600">
          Family plans were made to be shared. We handle the part that needs
          trust: the money.
        </p>
        <ol className="mt-8 grid gap-4 sm:grid-cols-2">
          {steps.map((s, i) => (
            <li
              key={s.title}
              className="rounded-2xl border border-stone-200 bg-white p-5 shadow-sm"
            >
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-brand-soft text-sm font-bold text-brand-strong">
                {i + 1}
              </span>
              <h3 className="mt-3 font-semibold">{s.title}</h3>
              <p className="mt-1 text-sm text-stone-600">{s.body}</p>
            </li>
          ))}
        </ol>
      </section>

      {/* Waitlist */}
      <section id="waitlist" className="bg-brand-soft/50">
        <div className="mx-auto max-w-3xl px-6 py-14 text-center sm:py-16">
          <h2 className="text-2xl font-bold">Launching in Kenya first 🇰🇪</h2>
          <p className="mx-auto mt-2 max-w-md text-stone-600">
            We&apos;re opening seat by seat so every member gets looked after.
            Waitlist opens soon.
          </p>
        </div>
      </section>

      <footer className="border-t border-stone-200">
        <div className="mx-auto flex max-w-3xl flex-col gap-2 px-6 py-8 text-sm text-stone-500 sm:flex-row sm:justify-between">
          <span>© {new Date().getFullYear()} Substribe</span>
          <span>Made in Nairobi · Lipa na M-Pesa</span>
        </div>
      </footer>
    </main>
  );
}
