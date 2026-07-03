# Substribe — Project Scope

**Version:** 1.0
**Owner:** Leslie Owuor
**Last updated:** 2026-07-01
**Status:** Product definition → build

---

## 0. One-liner

**Substribe is the trusted way for people in Kenya to split the cost of subscriptions they already share — Spotify, YouTube, Microsoft 365, ChatGPT Team — paid through M-Pesa, protected by escrow.**

We are Spliiit/GamsGo, built for East Africa, with trust and M-Pesa as the product — not features bolted on.

---

## 1. Positioning & thesis

### The insight
Premium subscriptions that define modern life and work — streaming, productivity, AI — are priced for rich-world individuals. In Kenya, $10–30/month is unaffordable for the students and young freelancers who most need these tools. But nearly all of these services **already support multiple people on one plan** (family plans, team seats). The cost per person, split correctly, is 60–80% lower.

The problem isn't technology. It's **trust and coordination**: finding people to split with, collecting money reliably, and guaranteeing nobody gets scammed or dropped. That's the gap Substribe fills.

### What we are
A **marketplace + light operator** that matches plan owners (people with empty seats) to buyers (people who want a seat), collects payment via M-Pesa, holds it in **escrow**, and releases it to the owner **only after the buyer confirms their access works**. We take a transparent margin.

### What we are NOT (explicit non-goals)
- ❌ **Not a credential-sharing / password-proxy service.** We only broker plans that support *separate logins per person* (admin-invite / family-invite / profile). We never ask an owner for their password and never hand a buyer someone else's login. This is a **hard product constraint** and a core trust promise.
- ❌ **Not an API proxy or "rent my ChatGPT Plus" service.** Single-user, non-invite subscriptions are out of scope. (Rationale in §14.)
- ❌ **Not a lender, not a crypto product, not a bank.**

### One mechanism, many services
Every service we support reduces to the same primitive: **a plan with multiple seats and an invite system.** Streaming, productivity, and AI team plans all run through **one code path**. This is the core architectural discipline — we resist any service that requires a bespoke sharing hack.

---

## 2. Users

| Persona | Who | Motivation | Primary role |
|---|---|---|---|
| **The Splitter (Owner)** | Owns a family/team plan, has empty seats | Recover cost, earn a little, no hassle | Lists seats, gets paid |
| **The Saver (Buyer)** | Student / young freelancer priced out | Access premium tools cheaply & safely | Joins a seat, pays monthly |
| **The Operator (Substribe)** | Us, later holding master accounts | Guarantee supply & reliability for top services | Owns plans, sells seats |
| **Ops/Trust Admin** | Internal | Resolve disputes, verify, prevent fraud | Uses admin console |

**Beachhead:** University students and young freelancers in Kenya (Nairobi first — JKUAT, UoN, Strathmore, Kenyatta, USIU corridors).
**Expansion path:** Kenya → Tanzania/Uganda → West Africa (Nigeria/Ghana) → South Asia.

---

## 3. Service catalogue

Grouped by the one mechanism (multi-seat + invite). Launch priority in §12.

### 3.1 Streaming & Music
- **Spotify Premium Family** (6 seats) — *launch candidate: high demand, clean invites, low support*
- **YouTube Premium Family** (5 seats) — *launch candidate*
- **Apple Music / Apple One Family**
- **Netflix** — ⚠️ *flagged.* Household enforcement (2023 crackdown) makes remote members fragile. **Excluded at launch**; revisit only via operator-held accounts on a single household connection, or drop entirely.

### 3.2 Productivity & Creative
- **Microsoft 365 Family** (6 users)
- **Google One** (storage sharing, 5 members)
- **Canva Teams**
- **Notion**, **Adobe** (team) — later

### 3.3 AI (team/business tiers only — never Plus/Pro individual)
- **ChatGPT Team** (admin invites members by email, per-seat)
- **Claude Team**
- **Perplexity Enterprise/Team**
- **Cursor** (team)
- **GitHub Copilot Business**
- **Google Workspace / Gemini Business**

> **Rule:** a service is only listable if a buyer receives their **own login/seat via an official invite**. If sharing it requires a password, it does not go on Substribe.

Each service in the catalogue carries metadata: seat count, official per-seat cost, invite mechanism, "same-household" requirement flag, ToS risk rating, and support-burden rating. This drives what we allow and how we message risk.

---

## 4. Core user flows

These are the flows we design and build to. Everything else is secondary.

### 4.1 Owner: List a plan
1. Sign up (phone + OTP; M-Pesa number is identity anchor).
2. Choose service from catalogue → system shows seat count & suggested price.
3. Confirm how many seats are free.
4. Set payout preference (M-Pesa number, verified against registered name).
5. Agree to owner terms (keep plan active, invite promptly, don't remove members).
6. Listing goes live → owner sees "You'll earn KSh X/seat/month after our fee."

### 4.2 Buyer: Find & join a seat
1. Sign up (phone + OTP).
2. Browse by service → see available seats with **transparent price breakdown** and **owner trust score**.
3. Tap "Join" → see exactly: what you pay, what the owner gets, what Substribe takes, the money-back guarantee, and next steps.
4. **Pay via M-Pesa STK push** → funds go to **escrow** (not the owner yet).
5. Enter the email the owner should invite.
6. **Owner receives instant WhatsApp/SMS**: "Invite [email] to your [service] plan within 12h to get paid KSh X."
7. Buyer accepts provider invite → **confirms in Substribe "I have access"** (or auto-detected where possible).
8. **Escrow releases to owner.** Buyer's seat is now Active.

### 4.3 The escrow & confirmation loop (the trust core)
- Money is **never** released until the buyer confirms working access.
- If the owner doesn't invite within the window → **auto-refund** to buyer, listing penalised.
- If invite works → release to owner minus fee.
- Confirmation defaults to explicit buyer tap; where a provider API allows verifying membership, auto-confirm.

### 4.4 Recurring billing
- Monthly cycle. **M-Pesa Ratiba (standing order / recurring API)** is the primary rail so buyers don't re-enter PIN monthly.
- **Fallback:** reminder-driven STK push (WhatsApp/SMS "tap to renew") 2 days before renewal.
- **Prepaid wallet option:** buyer tops up a Substribe wallet via M-Pesa; renewals debit the wallet. Reduces monthly friction and payment failure.

### 4.5 Dropped seat / remediation (the make-whole loop)
- Buyer reports "I lost access" (removed from plan / owner cancelled).
- **Next owner payout is instantly frozen.**
- SubBot attempts to **re-match the buyer to another live seat from the waitlist pool within minutes**, prorating the difference.
- If unresolved → **automatic refund of the unused portion + goodwill credit.**
- Owner reputation penalised; repeat offenders delisted.
- **Principle borrowed from Uber/Airbnb: speed of remedy beats existence of remedy.** The buyer should feel taken care of before they finish complaining.

### 4.6 Owner payout
- Batched or on-confirmation payout via **M-Pesa B2C**.
- Payout shows full breakdown; owner sees lifetime earnings.
- Held amounts (disputes, new-owner probation) clearly surfaced.

### 4.7 Waitlist & auto-fill
- Every service has a per-service waitlist.
- When a seat frees (buyer leaves) or a new plan lists, the top waitlisted buyer is matched automatically.
- Owners with empty seats are never idle for long → liquidity flywheel.

---

## 5. Trust & Safety system (the actual product)

African users have been burned by WhatsApp-group "subscription seller" scams and won't give a second chance. **Trust is not a feature here — it is the reason we exist.** Every design decision is filtered through "does this make a first-time user believe they won't lose their money?"

### 5.1 Escrow-first
- Buyer money is held by Substribe until access is confirmed. This single mechanism is our core differentiator over the WhatsApp gray market.
- Prominent, repeated messaging: **"Your money is safe until your subscription works."**

### 5.2 Identity & verification (tiered KYC)
| Tier | Requirement | Unlocks |
|---|---|---|
| 0 | Phone + OTP | Browse, join 1 seat |
| 1 | M-Pesa name match | Join multiple, list 1 plan |
| 2 | National ID / KRA PIN | List multiple plans, higher payout limits |
| 3 | (Operator/high-volume) enhanced checks | Bulk listings |

M-Pesa name matching is a cheap, high-signal verification unique to this market — use it aggressively.

### 5.3 Two-sided reputation
- **Owners** scored on: invite speed, seat uptime, months without incident, dispute rate.
- **Buyers** scored on: payment reliability (largely automatic via M-Pesa), behaviour.
- Scores visible. Below-threshold owners get restricted/delisted; below-threshold buyers lose access to premium listings.
- Display "trust proof": "★4.9 · 47 seats filled · 11 months active · 0 disputes."

### 5.4 Guarantees & insurance
- **Money-back guarantee** on any seat that fails within a cycle.
- **Insurance/reserve fund** funded from a slice of platform margin (real reserve, tracked in the ledger — not a vague "pool"). Caps our exposure by only operating invite-based services.

### 5.5 Fraud controls
- Velocity limits, device/number fingerprinting, duplicate-account detection.
- Anomaly flags: an owner listing 50 plans, mismatched names, chargeback-like refund abuse.
- Manual review queue in admin console.

### 5.6 Transparency
- Every transaction shows the full fee breakdown. No hidden cuts.
- Public trust page: how escrow works, what happens if something breaks, response-time commitments.

---

## 6. Payments architecture (M-Pesa is the primary rail)

**The payment flow IS the product.** It must be bulletproof and reconcilable to the shilling.

### 6.1 Rails
- **Collection (buyer → Substribe):** M-Pesa **STK Push** (Lipa na M-Pesa Online) via Daraja API; **C2B** confirmation for paybill/till.
- **Recurring:** **M-Pesa Ratiba** (standing orders) primary; reminder-STK-push and prepaid wallet as fallbacks (see §4.4).
- **Payout (Substribe → owner):** M-Pesa **B2C**.
- **Secondary rails (later):** Airtel Money, then card (Stripe/Flutterwave/Paystack) for diaspora & regional expansion.

### 6.2 Escrow ledger (double-entry)
- A proper **double-entry ledger in Postgres** — not "Stripe balance," not implicit state. Every movement is a balanced pair of entries.
- Account types: buyer-held (escrow), owner-payable, platform-revenue, insurance-reserve, M-Pesa-float, refunds.
- Every M-Pesa transaction (STK, C2B, B2C) is recorded with its M-Pesa receipt number and reconciled against Daraja callbacks and the transaction-status query API.

### 6.3 Edge cases we design for from day one
- **Async STK timeouts** — user doesn't enter PIN / callback never arrives → poll transaction status, don't assume failure or success.
- **Duplicate callbacks / idempotency** — every payment op keyed by an idempotency token; callbacks are safe to receive twice.
- **Partial refunds & prorating** — mid-cycle drops refund only the unused portion.
- **Failed recurring charge** — grace period, retries, then graceful seat suspension (not silent loss).
- **B2C float management** — monitor working-account balance; alert before payouts can't clear; batch payouts to manage float and M-Pesa transaction costs.
- **Reconciliation job** — nightly job reconciles ledger ↔ M-Pesa statement; flags any mismatch to ops.
- **Dispute holds** — a disputed seat freezes the linked owner payable automatically.
- **Reversals** — handle M-Pesa reversal timelines and how they reflect in the ledger.

### 6.4 Fee model
- **Margin over wholesale.** Buyer sees: seat price + Substribe fee, itemised.
- Example (illustrative): Spotify Family costs owner ~KSh 650/mo for 6 → wholesale per seat ~KSh 110. We list a seat at ~KSh 250: owner nets ~KSh 180, Substribe ~KSh 70, still ~80% cheaper than KSh 1,050 solo.
- Fee % is intentionally **lower than Spliiit-style 20–25%** on the *saving*, because our whole reason for existing is affordability. We tune per service.

### 6.5 Compliance
- Operate collections/payouts under a **registered Kenyan company** using M-Pesa Paybill/Till, and where required partner with a **licensed PSP/aggregator** rather than becoming a money transmitter ourselves.
- Avoid handling card PANs directly (PCI scope stays with Stripe/PSP).

---

## 7. SubBot — automation layer

Not a chat gimmick. A **background engine** with a thin messaging surface (WhatsApp) for the moments that matter.

- **Matching & auto-fill:** pair waitlisted buyers to open seats; keep liquidity high.
- **Renewal orchestration:** trigger Ratiba/STK reminders, retries, wallet debits.
- **Invite chasing:** nudge owners who haven't sent invites; escalate/refund on timeout.
- **Remediation:** detect dropped seats, re-match, prorate, refund — the make-whole loop.
- **Reputation & anomaly:** update scores, flag fraud patterns for admin.
- **Dead-plan / dormancy nudges:** "You have an empty Spotify seat — list it and earn KSh 180/mo."
- **Concierge (early phase):** guided onboarding over WhatsApp in English/Swahili/Sheng-friendly copy.

Interface: **WhatsApp Business Cloud API** for notifications and bot; SMS (Africa's Talking) as fallback for delivery reliability on any network.

---

## 8. Design & UX principles

Every screen must look like it belongs to a $10M company, because in Kenya a beautiful UI is the difference between "legit" and "scam."

- **Mobile-first, Android-first, low-bandwidth-first.** Built as a **PWA** (installable, offline states, tiny bundle, works on 3G). Optimise images, lazy-load, skeletons over spinners.
- **Trust signals placed with intention:** escrow badge, owner rating, "money safe until it works," fee transparency — exactly where hesitation happens (the pay screen).
- **Clear hierarchy, purposeful motion.** Micro-animations to confirm payment success, seat activation — motion that builds confidence, never decoration.
- **Localisation:** English + Swahili; KES formatting; copy that sounds Kenyan, warm, and human — not corporate.
- **Accessibility:** legible type, high contrast, large tap targets (thumb-first).
- **60-second demo rule:** every core flow must be demoable to an investor in under a minute.
- **Design system:** shared tokens (color, type, spacing), component library, consistent empty/loading/error states.

---

## 9. Technical architecture

### 9.1 Stack
| Layer | Choice | Why |
|---|---|---|
| Frontend | **Next.js (App Router) + TypeScript**, Tailwind, PWA | Fast, mobile-first, one codebase |
| UI | Component library on shared design tokens | Consistency, speed |
| Backend/DB | **Supabase** (Postgres, Auth, RLS, Realtime, Storage, Edge Functions) | Cheap, batteries-included, RLS for security |
| Payments | **M-Pesa Daraja** (STK, C2B, B2C, Ratiba) via a dedicated payments service/Edge Functions | Primary rail |
| Messaging | **WhatsApp Business Cloud API** + **Africa's Talking SMS** | Reach & reliability |
| Ledger | Postgres double-entry schema | Bulletproof money truth |
| Hosting | Vercel (web) + Supabase (backend) | Low cost, scales later |
| Monitoring | Sentry, structured logs, uptime alerts | Ops visibility |
| Later | React Native/Expo app; card PSP; more rails | Expansion |

### 9.2 Security
- Row-Level Security on all tenant data.
- No plaintext secrets; Supabase Vault / env for API keys.
- Webhook signature verification (M-Pesa, WhatsApp).
- Audit log on every money movement and admin action.
- Rate limiting on auth and payment endpoints.

### 9.3 Compliance & legal
- Register Kenyan company; **ODPC (Data Protection Act 2019) registration** as data controller.
- Terms of Service addressing the account-sharing gray area and shifting appropriate responsibility to plan owners re: provider ToS.
- Clear privacy policy; minimal PII; ID data encrypted and access-limited.

---

## 10. Data model (core entities)

- **User** (phone, kyc_tier, mpesa_name, reputation_score, role flags)
- **Service** (catalogue entry: seats, official_price, invite_mechanism, household_flag, risk_rating)
- **Plan/Listing** (owner_id, service_id, total_seats, open_seats, seat_price, status)
- **Seat** (listing_id, buyer_id, status: open|reserved|invited|active|suspended|ended, invite_email)
- **Subscription/Membership** (buyer_id, seat_id, cycle dates, billing_method)
- **Ledger Entry** (double-entry: account, debit/credit, amount, currency, ref)
- **Payment** (mpesa_type, receipt_no, status, idempotency_key, callbacks)
- **Payout** (owner_id, amount, status, mpesa_b2c_ref)
- **Dispute** (seat_id, reporter, status, resolution, hold_ref)
- **Rating/Review** (from_user, to_user, seat_id, score, comment)
- **Waitlist Entry** (buyer_id, service_id, position)
- **Notification** (channel, template, status)
- **AuditLog** (actor, action, target, before/after)

---

## 11. Admin & ops tooling

Ops is where trust is defended. Build the console early.
- Dispute queue with one-click refund / re-match / release.
- KYC review queue.
- Fraud/anomaly flags dashboard.
- Ledger & M-Pesa reconciliation view.
- Listing/catalogue management (add services, set risk flags, toggle availability).
- Manual matching override (concierge phase).
- User trust-score management, suspensions.

---

## 12. Roadmap (phases)

> Phasing is delivery order, not scope reduction — the full scope above is the destination.

**Phase 0 — Validate (weeks 0–4)**
Landing page + waitlist, WhatsApp/Telegram community, **manual concierge matching** for one service, M-Pesa via existing paybill, escrow enforced by hand. Prove demand + willingness to pay.

**Phase 1 — Core marketplace (the buildable heart)** — **LAUNCH VERTICAL: Spotify Premium Family (locked).**
Single vertical, full flows: auth → list → browse → join → **M-Pesa STK escrow** → invite-confirm → **B2C payout** → two-sided reputation → dispute/refund → waitlist. PWA, mobile-first, Swahili+English. This is the demoable product.
*Why Spotify first:* highest student impulse-demand, cleanest email-invite flow, lowest support burden, 6 seats fill fastest → quickest path to marketplace liquidity.

**Phase 2 — Breadth + automation**
Add **AI team plans** (ChatGPT/Claude Team) and productivity (M365, Canva) on the *same* code path. **WhatsApp bot** notifications, **recurring billing (Ratiba + wallet)**, auto re-fill, SubBot remediation.

**Phase 3 — Operator mode + growth**
Substribe holds **master accounts** for the 2–3 highest-demand services (with funding). **Referrals** (invite to fill a plan, price drops as it fills — built-in virality). Savings-flex share cards. Curated bundles.

**Phase 4 — Regional expansion**
Tanzania/Uganda; **Airtel Money** + more rails; native **Android app**; localisation.

**Phase 5 — Adjacent products**
Emerging-market **API-backed AI assistant** (legal, metered, M-Pesa micro-pay); anonymised subscription/pricing data products; wholesale/affiliate deals with providers.

---

## 13. Success metrics (KPIs)

- **Liquidity:** median time-to-fill a listed seat; % seats filled.
- **Reliability:** seat uptime %; dispute rate; median remediation time.
- **Trust:** refund rate, repeat-buyer rate, NPS, first-transaction completion rate.
- **Economics:** GMV, take rate, contribution margin per seat, CAC (esp. via referral), payback.
- **Retention:** average months a buyer stays; owner re-listing rate.
- **Growth:** referral coefficient (seats filled per inviting owner).

---

## 14. Key decisions & rationale (log)

1. **Model A (API proxy) dropped.** Products with idle capacity (Plus/Pro) have no API; API products are metered with no idle capacity. The premise was self-contradictory.
2. **No credential/session sharing.** You can't hide a secret from the device that must use it; client-side isolation always leaks. Server-side hosted-browser isolation is expensive, single-concurrency, fragile, and bannable — wrong for an unfunded startup. So we only broker invite-based, separate-login plans.
3. **AI = team tiers only.** They use the exact same admin-invite mechanism as family plans → one code path, no special case.
4. **Kenya-first, affordability thesis.** "Afford the unaffordable," not rich-world "waste recovery."
5. **Marketplace-first, operator-later hybrid.** No inventory risk while unfunded; hold master accounts only for proven top services.
6. **M-Pesa is the primary rail**, with a real double-entry ledger and reconciliation. Recurring solved via Ratiba + wallet + reminder-STK.
7. **Trust is the product.** Escrow, tiered KYC (M-Pesa name match), two-sided reputation, instant remediation, transparent fees.
8. **Netflix excluded at launch** due to household enforcement; catalogue carries per-service risk flags.

---

## 15. Open items needing founder input

- ~~Launch service~~ ✅ **DECIDED: Spotify Premium Family** (2026-07-01).
- Exact fee % per service.
- Company registration + PSP/aggregator partner selection (money-transmission compliance).
- Brand name lock, visual identity, Swahili/Sheng copy voice.
- Whether AI assistant (Phase 5) is in the near-term narrative for fundraising.
