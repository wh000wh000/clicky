-- Migration 04: Atomic chat quota check-and-increment RPC
-- Run in: Supabase Dashboard → SQL Editor
--
-- Replaces the read-then-write pattern in Worker's checkAndIncrementChatQuota()
-- with a single atomic RPC that uses SELECT ... FOR UPDATE to prevent races.
-- This guarantees that concurrent requests cannot bypass the daily quota limit.

CREATE OR REPLACE FUNCTION public.check_and_increment_chat_quota(user_uuid uuid)
RETURNS jsonb AS $$
DECLARE
    profile_record record;
    plan_limit int;
    today_date date := current_date;
BEGIN
    -- Lock the user's row to prevent concurrent reads
    SELECT plan, daily_chat_count, daily_chat_reset_at
    INTO profile_record
    FROM public.user_profiles
    WHERE id = user_uuid
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'user_not_found');
    END IF;

    -- Reset count if the stored reset date is before today (new calendar day)
    IF profile_record.daily_chat_reset_at < today_date THEN
        UPDATE public.user_profiles
        SET daily_chat_count = 0, daily_chat_reset_at = today_date
        WHERE id = user_uuid;
        profile_record.daily_chat_count := 0;
    END IF;

    -- Look up the plan's daily limit from the plans table
    SELECT daily_chat_limit INTO plan_limit
    FROM public.plans
    WHERE id = profile_record.plan;

    IF plan_limit IS NULL THEN
        plan_limit := 20; -- fallback to free tier default
    END IF;

    -- Check if the user has exceeded their daily quota
    IF profile_record.daily_chat_count >= plan_limit THEN
        RETURN jsonb_build_object(
            'allowed', false,
            'plan', profile_record.plan,
            'daily_limit', plan_limit,
            'used_today', profile_record.daily_chat_count,
            'remaining', 0
        );
    END IF;

    -- Atomically increment both daily and total counts
    UPDATE public.user_profiles
    SET daily_chat_count = daily_chat_count + 1,
        total_chat_count = total_chat_count + 1
    WHERE id = user_uuid;

    RETURN jsonb_build_object(
        'allowed', true,
        'plan', profile_record.plan,
        'daily_limit', plan_limit,
        'used_today', profile_record.daily_chat_count + 1,
        'remaining', plan_limit - profile_record.daily_chat_count - 1
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
