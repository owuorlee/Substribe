"use client";

// The payment moment. Rules: the buyer must always know (1) exactly what will
// happen next and (2) whether their money has moved. Every state below keeps
// those two promises.

import { useRef, useState } from "react";
import Link from "next/link";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { supabaseBrowser } from "@/lib/supabase/client";
import { fmtKes, normalizeKenyanPhone } from "@/lib/format";

type Phase =
  | { name: "form" }
  | { name: "sending" }
  | { name: "prompted"; paymentId: string }
  | { name: "confirming"; paymentId: string }
  | { name: "paid" }
  | { name: "failed"; message: string };

const POLL_INTERVAL_MS = 3000;
const POLL_LIMIT = 40; // ~2 minutes

export default function PayForm({
  seatId,
  amountCents,
  defaultPhone,
  slaHours,
}: {
  seatId: string;
  amountCents: number;
  defaultPhone: string;
  slaHours: number;
}) {
  const [email, setEmail] = useState("");
  const [phoneInput, setPhoneInput] = useState(defaultPhone);
  const [phase, setPhase] = useState<Phase>({ name: "form" });
  const [formError, setFormError] = useState<string | null>(null);
  const pollCount = useRef(0);

  async function pay(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);

    const phone = normalizeKenyanPhone(phoneInput);
    if (!phone) {
      setFormError("Enter a valid Kenyan mobile number, e.g. 0712 345 678.");
      return;
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())) {
      setFormError("Enter the email where your invite should be sent.");
      return;
    }

    setPhase({ name: "sending" });
    const supabase = supabaseBrowser();
    const { data, error } = await supabase.functions.invoke("mpesa-stk-initiate", {
      body: { seat_id: seatId, invite_email: email.trim(), phone },
    });

    if (error) {
      let message = "Something went wrong. Your money has NOT moved.";
      if (error instanceof FunctionsHttpError) {
        const body = await error.context.json().catch(() => null);
        if (body?.message) message = body.message;
      }
      setPhase({ name: "failed", message });
      return;
    }

    pollCount.current = 0;
    setPhase({ name: "prompted", paymentId: data.payment_id });
    poll(data.payment_id);
  }

  async function poll(paymentId: string) {
    const supabase = supabaseBrowser();
    while (pollCount.current < POLL_LIMIT) {
      pollCount.current += 1;
      await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
      const { data } = await supabase
        .from("payments")
        .select("status, failure_reason")
        .eq("id", paymentId)
        .maybeSingle();

      if (data?.status === "succeeded") {
        setPhase({ name: "paid" });
        return;
      }
      if (data?.status === "failed") {
        setPhase({
          name: "failed",
          message: friendlyFailure(data.failure_reason),
        });
        return;
      }
      if (data?.status === "timeout" || pollCount.current > 10) {
        setPhase({ name: "confirming", paymentId });
      }
    }
    setPhase({
      name: "failed",
      message:
        "We haven't received M-Pesa's confirmation yet. If you entered your PIN, don't pay again — check your dashboard in a few minutes; your seat is held for you.",
    });
  }

  if (phase.name === "paid") {
    return (
      <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-6 text-center">
        <p className="text-3xl">🎉</p>
        <h2 className="mt-2 text-lg font-bold text-emerald-900">
          {fmtKes(amountCents)} is safely in escrow
        </h2>
        <p className="mt-2 text-sm text-emerald-800">
          The owner has {slaHours} hours to send your invite to{" "}
          <span className="font-semibold">{email}</span>. Accept it, then
          confirm here — only then do they get paid. No invite? Automatic
          refund, no questions asked.
        </p>
        <Link
          href="/dashboard"
          className="mt-5 inline-block rounded-xl bg-brand px-6 py-3 font-semibold text-white"
        >
          Go to my dashboard
        </Link>
      </div>
    );
  }

  if (phase.name === "prompted" || phase.name === "confirming") {
    return (
      <div className="rounded-2xl border border-stone-200 bg-white p-6 text-center">
        <div className="mx-auto h-10 w-10 animate-spin rounded-full border-4 border-brand-soft border-t-brand" />
        <h2 className="mt-4 font-bold">
          {phase.name === "prompted"
            ? "Check your phone"
            : "Confirming with M-Pesa…"}
        </h2>
        <p className="mt-2 text-sm text-stone-600">
          {phase.name === "prompted"
            ? `Enter your M-Pesa PIN on the prompt to pay ${fmtKes(amountCents)}.`
            : "This can take a minute on a slow network. Don't pay again — we'll update this screen the moment M-Pesa responds."}
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={pay} className="space-y-4">
      <label className="block">
        <span className="text-sm font-medium">Email for your invite</span>
        <input
          type="email"
          required
          placeholder="you@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
        />
        <span className="mt-1 block text-xs text-stone-500">
          The plan owner adds this email — you get your own login.
        </span>
      </label>

      <label className="block">
        <span className="text-sm font-medium">M-Pesa number to charge</span>
        <input
          type="tel"
          inputMode="tel"
          required
          placeholder="0712 345 678"
          value={phoneInput}
          onChange={(e) => setPhoneInput(e.target.value)}
          className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
        />
      </label>

      {(formError || phase.name === "failed") && (
        <p className="rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">
          {formError ?? (phase.name === "failed" ? phase.message : "")}
        </p>
      )}

      <button
        type="submit"
        disabled={phase.name === "sending"}
        className="w-full rounded-xl bg-brand px-6 py-4 text-lg font-semibold text-white shadow-lg transition hover:bg-brand-strong disabled:opacity-60"
      >
        {phase.name === "sending"
          ? "Sending prompt…"
          : `Pay ${fmtKes(amountCents)} with M-Pesa`}
      </button>
      <p className="text-center text-xs text-stone-500">
        🔒 Held in escrow until your seat works
      </p>
    </form>
  );
}

function friendlyFailure(reason: string | null): string {
  const r = reason ?? "";
  if (r.includes("1032")) return "You cancelled the M-Pesa prompt. Tap pay to try again.";
  if (r.includes("(code 1)")) return "Your M-Pesa balance is too low. Top up and try again.";
  if (r.includes("2001")) return "Wrong M-Pesa PIN entered. Tap pay to try again.";
  if (r.includes("1037")) return "We couldn't reach your phone. Check your signal and try again.";
  return "The payment didn't go through — no money left your account. Please try again.";
}
