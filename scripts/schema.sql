-- Clicky 数据库表设计
-- 部署到 Supabase (Singapore region)

-- 1. 用户配置表（扩展 Supabase auth.users）
create table public.user_profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text,
    avatar_url text,
    -- 套餐信息
    plan text not null default 'free' check (plan in ('free', 'pro', 'premium')),
    plan_expires_at timestamptz,
    -- 用量统计
    daily_chat_count int not null default 0,
    daily_chat_reset_at date not null default current_date,
    total_chat_count bigint not null default 0,
    -- 邀请码
    invite_code text unique,
    invited_by uuid references public.user_profiles(id),
    invited_count int not null default 0,
    invitation_verified boolean not null default false,
    -- 时间戳
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- 2. 邀请码表
create table public.invitation_codes (
    id uuid primary key default gen_random_uuid(),
    code text unique not null,
    created_by uuid references public.user_profiles(id),
    -- 使用限制
    max_uses int not null default 1,
    used_count int not null default 0,
    -- 状态
    is_active boolean not null default true,
    expires_at timestamptz,
    -- 时间戳
    created_at timestamptz not null default now()
);

-- 3. 邀请使用记录
create table public.invitation_uses (
    id uuid primary key default gen_random_uuid(),
    code_id uuid not null references public.invitation_codes(id),
    used_by uuid not null references public.user_profiles(id),
    used_at timestamptz not null default now()
);

-- 4. API 调用日志（用量计量）
create table public.api_usage_logs (
    id bigint generated always as identity primary key,
    user_id uuid not null references public.user_profiles(id),
    api_type text not null check (api_type in ('chat', 'tts', 'stt')),
    model text,
    -- 计量
    input_tokens int,
    output_tokens int,
    duration_ms int,
    -- 时间戳
    created_at timestamptz not null default now()
);

-- 5. 套餐定义表
create table public.plans (
    id text primary key,
    name text not null,
    description text,
    -- 额度
    daily_chat_limit int not null,
    -- 定价（分为单位）
    price_cents int not null default 0,
    price_period text check (price_period in ('monthly', 'yearly', 'lifetime')),
    -- 状态
    is_active boolean not null default true,
    created_at timestamptz not null default now()
);

-- 初始套餐数据
insert into public.plans (id, name, description, daily_chat_limit, price_cents, price_period) values
    ('free', '免费版', '每日 20 次对话', 20, 0, null),
    ('pro', '专业版', '每日 200 次对话', 200, 2900, 'monthly'),
    ('premium', '旗舰版', '无限对话', 999999, 9900, 'monthly');

-- 索引
create index idx_api_usage_user_date on public.api_usage_logs (user_id, created_at);
create index idx_invitation_codes_code on public.invitation_codes (code) where is_active = true;
create index idx_user_profiles_invite_code on public.user_profiles (invite_code);

-- RLS 策略
alter table public.user_profiles enable row level security;
alter table public.invitation_codes enable row level security;
alter table public.invitation_uses enable row level security;
alter table public.api_usage_logs enable row level security;
alter table public.plans enable row level security;

-- 用户只能读写自己的 profile
create policy "Users can read own profile" on public.user_profiles
    for select using (auth.uid() = id);
create policy "Users can update own profile" on public.user_profiles
    for update using (auth.uid() = id);

-- 所有人可以读取活跃的邀请码（用于验证）
create policy "Anyone can read active invitation codes" on public.invitation_codes
    for select using (is_active = true);

-- 用户可以读自己的使用记录
create policy "Users can read own usage" on public.api_usage_logs
    for select using (auth.uid() = user_id);

-- 所有人可以读套餐定义
create policy "Anyone can read plans" on public.plans
    for select using (true);

-- 触发器：注册时自动创建 profile + 生成邀请码
create or replace function public.handle_new_user()
returns trigger as $$
declare
    new_invite_code text;
begin
    -- 生成 8 位邀请码
    new_invite_code := upper(substr(md5(random()::text), 1, 8));

    insert into public.user_profiles (id, invite_code)
    values (new.id, new_invite_code);

    return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- 函数：验证并使用邀请码
create or replace function public.use_invitation_code(invitation_code text, user_uuid uuid)
returns boolean as $$
declare
    code_record record;
begin
    -- Case-insensitive code matching (uppercased on input)
    select * into code_record
    from public.invitation_codes
    where code = upper(invitation_code)
      and is_active = true
      and (expires_at is null or expires_at > now())
      and used_count < max_uses;

    if not found then
        return false;
    end if;

    -- Prevent the same user from redeeming the same code twice
    if exists (
        select 1 from public.invitation_uses
        where code_id = code_record.id and used_by = user_uuid
    ) then
        return false;
    end if;

    -- 记录使用
    insert into public.invitation_uses (code_id, used_by)
    values (code_record.id, user_uuid);

    -- 更新使用次数
    update public.invitation_codes
    set used_count = used_count + 1
    where id = code_record.id;

    -- 更新邀请人的邀请计数
    if code_record.created_by is not null then
        update public.user_profiles
        set invited_count = invited_count + 1
        where id = code_record.created_by;
    end if;

    -- 标记被邀请人已验证，并记录邀请来源
    update public.user_profiles
    set invitation_verified = true,
        invited_by = code_record.created_by
    where id = user_uuid;

    return true;
end;
$$ language plpgsql security definer;
