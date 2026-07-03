-- Substribe · Service catalogue seed
-- Prices are KES cents, monthly-normalised, mid-2026 estimates. Rule: verify
-- current Kenyan pricing before flipping any service to is_active = true.
-- Only Spotify Premium Family is live at launch (SCOPE.md Phase 1, locked).

insert into public.services
  (slug, name, category, seats_total, plan_price_cents, official_solo_price_cents,
   suggested_seat_price_cents, currency, invite_mechanism, household_required,
   risk, support_burden, is_active, notes)
values
  (
    'spotify-family', 'Spotify Premium Family', 'music',
    6, 95900, 59900, 25000, 'KES', 'link_invite', true,
    'low', 'low', true,
    'LAUNCH SERVICE. Owner shares an invite link; member enters the owner''s address at join. Address enforcement is light but real — onboarding copy must coach both sides. Seat at KSh 250 vs KSh 599 solo = 58% saving; 5 seats at KSh 250 nearly covers the owner''s KSh 959 plan.'
  ),
  (
    'youtube-premium-family', 'YouTube Premium Family', 'streaming',
    6, 104900, 54900, 30000, 'KES', 'email_invite', true,
    'low', 'low', false,
    'Phase 2. Google family group; members must be in the same country. Clean email invite flow.'
  ),
  (
    'microsoft-365-family', 'Microsoft 365 Family', 'productivity',
    6, 90000, 65000, 25000, 'KES', 'email_invite', false,
    'low', 'low', false,
    'Phase 2. Each member gets own Office apps + 1TB OneDrive. Prices are estimates — verify local pricing before activation.'
  ),
  (
    'google-one-2tb', 'Google One 2TB', 'storage',
    6, 109900, 109900, 25000, 'KES', 'email_invite', false,
    'low', 'low', false,
    'Phase 2/3. Storage is shared from one 2TB pool, not per-member — listing copy must say so. Officially supported family sharing; cleanest ToS fit in the catalogue.'
  ),
  (
    'chatgpt-team', 'ChatGPT Team', 'ai',
    5, 1600000, 260000, null, 'KES', 'email_invite', false,
    'medium', 'medium', false,
    'PRICING MODEL OPEN — do not activate. Team is priced PER SEAT (~USD 25/seat), so splitting yields no discount vs Plus. The value we add is different: M-Pesa access for users without international cards, and pooling to meet minimum-seat requirements. Decide pricing (payment-rail margin) before activation.'
  ),
  (
    'claude-team', 'Claude Team', 'ai',
    5, 1900000, 260000, null, 'KES', 'email_invite', false,
    'medium', 'medium', false,
    'PRICING MODEL OPEN — do not activate. Same per-seat economics as ChatGPT Team, plus a 5-seat minimum a solo freelancer cannot meet alone. Value = min-seat pooling + M-Pesa rail.'
  ),
  (
    'netflix-standard', 'Netflix Standard', 'streaming',
    2, 110000, 110000, null, 'KES', 'profile_add', true,
    'high', 'high', false,
    'EXCLUDED AT LAUNCH (SCOPE.md §3.1, decision log #8). Household/IP enforcement since 2023 makes remote members fragile. Catalogued for completeness only.'
  )
on conflict (slug) do nothing;
