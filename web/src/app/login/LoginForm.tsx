"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";
import { normalizeKenyanPhone } from "@/lib/format";

type Step = "phone" | "code" | "dev";

// Dev-only email/password sign-in. Gated behind NEXT_PUBLIC_DEV_LOGIN so it
// can never reach production; lets us test the full loop before an SMS
// provider is wired up. Real users always use phone + OTP.
const DEV_LOGIN = process.env.NEXT_PUBLIC_DEV_LOGIN === "true";

export default function LoginForm({ next }: { next: string }) {
  const router = useRouter();
  const [step, setStep] = useState<Step>("phone");
  const [phoneInput, setPhoneInput] = useState("");
  const [phone, setPhone] = useState(""); // normalized E.164
  const [code, setCode] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function devAuth(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const supabase = supabaseBrowser();
      let res = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (res.error) {
        // First time with this email → create the account, then sign in.
        const signUp = await supabase.auth.signUp({ email: email.trim(), password });
        if (signUp.error) throw new Error(signUp.error.message);
        res = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (res.error) {
          throw new Error(
            "Account created. If sign-in fails, disable 'Confirm email' in Supabase Auth settings for dev.",
          );
        }
      }
      router.push(next);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Dev sign-in failed.");
    } finally {
      setBusy(false);
    }
  }

  async function sendCode(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const normalized = normalizeKenyanPhone(phoneInput);
    if (!normalized) {
      setError("Enter a valid Kenyan mobile number, e.g. 0712 345 678.");
      return;
    }
    setBusy(true);
    try {
      const supabase = supabaseBrowser();
      const { error } = await supabase.auth.signInWithOtp({ phone: normalized });
      if (error) throw new Error(error.message);
      setPhone(normalized);
      setStep("code");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not send the code.");
    } finally {
      setBusy(false);
    }
  }

  async function verifyCode(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const supabase = supabaseBrowser();
      const { error } = await supabase.auth.verifyOtp({
        phone,
        token: code.trim(),
        type: "sms",
      });
      if (error) throw new Error("That code didn't match. Check it and try again.");
      router.push(next);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Verification failed.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="mx-auto w-full max-w-md flex-1 px-6 py-14">
      <h1 className="text-2xl font-bold">
        {step === "dev"
          ? "Dev sign-in"
          : step === "phone"
            ? "Sign in with your phone"
            : "Enter the code"}
      </h1>
      <p className="mt-2 text-sm text-stone-600">
        {step === "dev"
          ? "Email + password — testing only. Real users sign in with their phone."
          : step === "phone"
            ? "Your number is your account — the same one you use for M-Pesa. We'll text you a code, no password needed."
            : `We sent a 6-digit code by SMS to ${phone}.`}
      </p>

      {step === "dev" ? (
        <form onSubmit={devAuth} className="mt-6 space-y-4">
          <label className="block">
            <span className="text-sm font-medium">Email</span>
            <input
              type="email"
              autoComplete="email"
              required
              placeholder="test@substribe.dev"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
            />
          </label>
          <label className="block">
            <span className="text-sm font-medium">Password</span>
            <input
              type="password"
              autoComplete="current-password"
              required
              minLength={6}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="w-full rounded-xl bg-brand px-6 py-3.5 font-semibold text-white transition hover:bg-brand-strong disabled:opacity-60"
          >
            {busy ? "Signing in…" : "Sign in / create account"}
          </button>
          <button
            type="button"
            onClick={() => {
              setStep("phone");
              setError(null);
            }}
            className="w-full text-sm text-stone-500 hover:text-stone-700"
          >
            Back to phone sign-in
          </button>
        </form>
      ) : step === "phone" ? (
        <form onSubmit={sendCode} className="mt-6 space-y-4">
          <label className="block">
            <span className="text-sm font-medium">M-Pesa phone number</span>
            <input
              type="tel"
              inputMode="tel"
              autoComplete="tel"
              required
              placeholder="0712 345 678"
              value={phoneInput}
              onChange={(e) => setPhoneInput(e.target.value)}
              className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 text-lg outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="w-full rounded-xl bg-brand px-6 py-3.5 font-semibold text-white transition hover:bg-brand-strong disabled:opacity-60"
          >
            {busy ? "Sending…" : "Text me a code"}
          </button>
        </form>
      ) : (
        <form onSubmit={verifyCode} className="mt-6 space-y-4">
          <label className="block">
            <span className="text-sm font-medium">6-digit code</span>
            <input
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              required
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className="mt-1 w-full rounded-xl border border-stone-300 bg-white px-4 py-3 text-center text-2xl tracking-[0.5em] outline-none focus:border-brand focus:ring-2 focus:ring-brand-soft"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="w-full rounded-xl bg-brand px-6 py-3.5 font-semibold text-white transition hover:bg-brand-strong disabled:opacity-60"
          >
            {busy ? "Checking…" : "Sign in"}
          </button>
          <button
            type="button"
            onClick={() => {
              setStep("phone");
              setCode("");
              setError(null);
            }}
            className="w-full text-sm text-stone-500 hover:text-stone-700"
          >
            Use a different number
          </button>
        </form>
      )}

      {error && (
        <p className="mt-4 rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </p>
      )}

      {DEV_LOGIN && step === "phone" && (
        <button
          type="button"
          onClick={() => {
            setStep("dev");
            setError(null);
          }}
          className="mt-8 w-full rounded-lg border border-dashed border-stone-300 py-2 text-xs font-medium text-stone-400 hover:text-stone-600"
        >
          Dev sign-in (email + password)
        </button>
      )}
    </main>
  );
}
