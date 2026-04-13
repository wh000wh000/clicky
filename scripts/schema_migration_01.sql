-- Migration 01: invitation_verified + updated use_invitation_code RPC
-- Run in: Supabase Dashboard → SQL Editor

-- 1. Add invitation_verified column
--    Defaults to false so existing users are gated until they enter a code.
ALTER TABLE public.user_profiles
ADD COLUMN IF NOT EXISTS invitation_verified boolean NOT NULL DEFAULT false;

-- 2. Replace use_invitation_code() with updated version that:
--    - Case-insensitive code matching (uppercased on input)
--    - Prevents the same user from using the same code twice
--    - Sets invitation_verified = true on success
CREATE OR REPLACE FUNCTION public.use_invitation_code(invitation_code text, user_uuid uuid)
RETURNS boolean AS $$
DECLARE
    code_record record;
BEGIN
    SELECT * INTO code_record
    FROM public.invitation_codes
    WHERE code = upper(invitation_code)
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > now())
      AND used_count < max_uses;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    -- Prevent the same user from redeeming the same code twice
    IF EXISTS (
        SELECT 1 FROM public.invitation_uses
        WHERE code_id = code_record.id AND used_by = user_uuid
    ) THEN
        RETURN false;
    END IF;

    -- Record the use
    INSERT INTO public.invitation_uses (code_id, used_by)
    VALUES (code_record.id, user_uuid);

    -- Increment code's used_count
    UPDATE public.invitation_codes
    SET used_count = used_count + 1
    WHERE id = code_record.id;

    -- Increment inviter's invited_count (if code was created by a user)
    IF code_record.created_by IS NOT NULL THEN
        UPDATE public.user_profiles
        SET invited_count = invited_count + 1
        WHERE id = code_record.created_by;
    END IF;

    -- Mark the redeemer as verified and record who invited them
    UPDATE public.user_profiles
    SET invitation_verified = true,
        invited_by          = code_record.created_by
    WHERE id = user_uuid;

    RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Seed initial invitation codes for early testing
--    (Admin can add more via Supabase Dashboard → Table Editor → invitation_codes)
INSERT INTO public.invitation_codes (code, max_uses, is_active) VALUES
    ('CLICKY01',  100, true),
    ('CLICKY02',  100, true),
    ('EARLYBIRD',  50, true)
ON CONFLICT (code) DO NOTHING;
