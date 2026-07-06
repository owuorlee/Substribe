"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

// Both actions call self-authorising Postgres RPCs (auth.uid() checks inside).

export function ConfirmAccessButton({ seatId }: { seatId: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function confirm() {
    setBusy(true);
    setError(null);
    const supabase = supabaseBrowser();
    const { error } = await supabase.rpc("confirm_seat_access", {
      p_seat_id: seatId,
    });
    setBusy(false);
    if (error) {
      setError("Couldn't confirm — refresh and try again, or contact support.");
      return;
    }
    router.refresh();
  }

  return (
    <div className="mt-2">
      <button
        onClick={confirm}
        disabled={busy}
        className="w-full rounded-xl bg-brand px-5 py-3 font-semibold text-white transition hover:bg-brand-strong disabled:opacity-60 sm:w-auto"
      >
        {busy ? "Confirming…" : "✓ I have access — release payment"}
      </button>
      {error && <p className="mt-2 text-sm text-red-600">{error}</p>}
    </div>
  );
}

export function MarkInvitedButton({
  seatId,
  inviteEmail,
}: {
  seatId: string;
  inviteEmail: string;
}) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function markInvited() {
    setBusy(true);
    setError(null);
    const supabase = supabaseBrowser();
    const { error } = await supabase.rpc("mark_seat_invited", {
      p_seat_id: seatId,
    });
    setBusy(false);
    if (error) {
      setError("Couldn't update — refresh and try again.");
      return;
    }
    router.refresh();
  }

  return (
    <div className="shrink-0 text-right">
      <button
        onClick={markInvited}
        disabled={busy}
        title={`Confirm you've invited ${inviteEmail} on the provider's site`}
        className="rounded-xl bg-brand px-4 py-2 text-xs font-semibold text-white transition hover:bg-brand-strong disabled:opacity-60"
      >
        {busy ? "Saving…" : "I've sent the invite"}
      </button>
      {error && <p className="mt-1 text-xs text-red-600">{error}</p>}
    </div>
  );
}
