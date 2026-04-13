-- =============================================================================
-- Migration 02: Phase 4 — Stripe subscription columns
-- =============================================================================
-- Run this against your Supabase project via the SQL editor or psql.
-- Idempotent: uses IF NOT EXISTS / DO $$ guards throughout.
-- =============================================================================

-- Add Stripe columns to user_profiles.
-- stripe_customer_id     — Stripe Customer object ID (cus_...)
--                          Set when the user completes their first checkout.
-- stripe_subscription_id — Stripe Subscription object ID (sub_...)
--                          Used to identify the active subscription for portal
--                          management and cancellation flows.
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS stripe_customer_id     TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT;

-- Index for fast Stripe-customer-ID → user lookups.
-- The webhook handler receives events keyed by customer ID and must resolve
-- the Supabase user UUID to update the plan column.
CREATE INDEX IF NOT EXISTS user_profiles_stripe_customer_id_idx
  ON public.user_profiles (stripe_customer_id);

-- =============================================================================
-- RLS policies
-- =============================================================================
-- The stripe_customer_id and stripe_subscription_id columns are written
-- exclusively by the Worker (service role key, bypasses RLS) and should be
-- read-only for authenticated users.  No additional client-facing policy is
-- needed beyond the existing user_profiles SELECT policy.
-- =============================================================================
