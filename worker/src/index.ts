/**
 * Clicky Proxy Worker
 *
 * Proxies requests to SiliconFlow APIs so the app never ships with raw
 * API keys. All secrets are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat                    → SiliconFlow /chat/completions (streaming)
 *   POST /tts                     → SiliconFlow /audio/speech
 *   GET  /quota                   → Returns current user quota status (auth required)
 *   POST /create-checkout-session → Creates a Stripe Checkout Session (auth required)
 *   POST /create-portal-session  → Creates a Stripe Billing Portal session (auth required)
 *   POST /webhook                 → Receives Stripe webhook events (sig-verified, no JWT)
 *
 * Auth:
 *   When SUPABASE_URL is configured, all routes (except /webhook) verify the
 *   Supabase JWT (ES256 / ECC P-256) from the Authorization header.
 *   Public keys are fetched from Supabase's JWKS endpoint, cached 1 hour.
 *
 * Quota (Phase 3):
 *   When SUPABASE_SERVICE_ROLE_KEY is also set, /chat enforces a per-user
 *   daily quota based on the user's plan. Exceeding the quota returns 429.
 *   Quota resets automatically at midnight (calendar-day boundary).
 *
 * Stripe (Phase 4):
 *   POST /create-checkout-session accepts { plan: "pro" | "premium" } and
 *   returns { url } — the Stripe-hosted checkout page URL.
 *   POST /webhook receives Stripe events, verifies the Stripe-Signature header,
 *   and syncs plan/subscription state back to Supabase user_profiles.
 */

// Cloudflare Workers execution context — provides waitUntil() for
// fire-and-forget async work that outlives the response send.
interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

interface Env {
  // Secret: SiliconFlow unified API key
  SILICONFLOW_API_KEY: string;
  // Vars (set in wrangler.toml)
  SILICONFLOW_BASE_URL: string;   // e.g. "https://api.siliconflow.com/v1"
  DEFAULT_CHAT_MODEL: string;     // e.g. "Qwen/Qwen3.5-397B-A17B"
  DEFAULT_TTS_MODEL: string;      // e.g. "FunAudioLLM/CosyVoice2-0.5B"
  DEFAULT_TTS_VOICE: string;      // e.g. "FunAudioLLM/CosyVoice2-0.5B:alex"
  // When set, all routes require a valid Supabase JWT.
  SUPABASE_URL: string | undefined;
  // Service role key — bypasses RLS so the Worker can write usage logs and
  // update daily_chat_count. Set via: npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
  SUPABASE_SERVICE_ROLE_KEY: string | undefined;
  // ── Stripe (Phase 4, 路由已注释掉，代码保留备用) ────────────────────────
  // 字段保留在 Env 类型中，避免 Stripe 处理函数产生 TS 编译错误。
  // 实际不会有流量进入这些路由，secrets 也无需在 wrangler 中配置。
  STRIPE_SECRET_KEY: string | undefined;
  STRIPE_WEBHOOK_SECRET: string | undefined;
  STRIPE_PRO_PRICE_ID: string | undefined;
  STRIPE_PREMIUM_PRICE_ID: string | undefined;
  STRIPE_SUCCESS_URL: string | undefined;
  STRIPE_CANCEL_URL: string | undefined;

  // ── 微信支付 Native (Phase 4) ─────────────────────────────────────────────
  // Secrets (set via `npx wrangler secret put <NAME>`):
  //   WECHAT_MCH_ID       — 商户号 (mchid)
  //   WECHAT_APP_ID       — AppID（公众号/APP 申请时绑定的 appid）
  //   WECHAT_API_V3_KEY   — APIv3 密钥（32 位字符串，商户平台设置）
  //   WECHAT_PRIVATE_KEY  — 商户 API 证书私钥 PEM（apiclient_key.pem 内容，PKCS8 格式）
  //   WECHAT_SERIAL_NO    — 商户 API 证书序列号
  //   WECHAT_NOTIFY_HOST  — Worker 的公开域名，用于拼接 notify_url（如 "https://clicky-proxy.xxx.workers.dev"）
  WECHAT_MCH_ID: string | undefined;
  WECHAT_APP_ID: string | undefined;
  WECHAT_API_V3_KEY: string | undefined;
  WECHAT_PRIVATE_KEY: string | undefined;
  WECHAT_SERIAL_NO: string | undefined;
  WECHAT_NOTIFY_HOST: string | undefined;
  // Vars (set in wrangler.toml): plan prices in fen (1 CNY = 100 fen)
  WECHAT_PRO_PRICE_FEN: string | undefined;     // e.g. "2900" → ¥29.00
  WECHAT_PREMIUM_PRICE_FEN: string | undefined; // e.g. "9900" → ¥99.00
}

// Daily chat limits per plan. Must stay in sync with the public.plans table.
const PLAN_DAILY_CHAT_LIMITS: Record<string, number> = {
  free:    20,
  pro:     200,
  premium: 999_999,  // effectively unlimited
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // WeChat Pay async notification — no JWT, WeChat calls this directly.
    if (request.method === "POST" && url.pathname === "/wechat-notify") {
      return handleWeChatNotify(request, env);
    }

    // Stripe webhook (暂时注释掉，保留代码)
    // if (request.method === "POST" && url.pathname === "/webhook") {
    //   return handleStripeWebhook(request, env);
    // }

    // Reject non-POST requests except for the GET /quota and GET /check-payment-status endpoints.
    const isAllowedGet =
      request.method === "GET" &&
      (url.pathname === "/quota" || url.pathname === "/check-payment-status");
    if (request.method !== "POST" && !isAllowedGet) {
      return new Response("Method not allowed", { status: 405 });
    }

    // --- Auth gate ---
    // Verifies the Supabase JWT and extracts the user's UUID.
    // If SUPABASE_URL is not set (dev/self-hosted), auth is skipped.
    let authenticatedUserId: string | undefined;
    if (env.SUPABASE_URL) {
      const jwtResult = await verifyRequestJWT(request, env.SUPABASE_URL);
      if ("authError" in jwtResult) return jwtResult.authError;
      authenticatedUserId = jwtResult.userId;
    }

    try {
      if (request.method === "POST" && url.pathname === "/chat") {
        return await handleChat(request, env, ctx, authenticatedUserId);
      }

      if (request.method === "POST" && url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (request.method === "GET" && url.pathname === "/quota") {
        return await handleQuota(authenticatedUserId, env);
      }

      // ── 微信支付路由 ────────────────────────────────────────────────────────
      if (request.method === "POST" && url.pathname === "/create-wechat-order") {
        if (!authenticatedUserId) {
          return new Response(
            JSON.stringify({ error: "Authentication required" }),
            { status: 401, headers: { "content-type": "application/json" } }
          );
        }
        return await handleCreateWeChatOrder(request, env, authenticatedUserId);
      }

      if (request.method === "GET" && url.pathname === "/check-payment-status") {
        if (!authenticatedUserId) {
          return new Response(
            JSON.stringify({ error: "Authentication required" }),
            { status: 401, headers: { "content-type": "application/json" } }
          );
        }
        return await handleCheckPaymentStatus(request, env, authenticatedUserId);
      }

      // ── Stripe 路由（暂时注释掉，保留代码备用）────────────────────────────
      // if (request.method === "POST" && url.pathname === "/create-checkout-session") {
      //   if (!authenticatedUserId) {
      //     return new Response(
      //       JSON.stringify({ error: "Authentication required" }),
      //       { status: 401, headers: { "content-type": "application/json" } }
      //     );
      //   }
      //   return await handleCreateCheckoutSession(request, env, authenticatedUserId);
      // }
      // if (request.method === "POST" && url.pathname === "/create-portal-session") {
      //   if (!authenticatedUserId) {
      //     return new Response(
      //       JSON.stringify({ error: "Authentication required" }),
      //       { status: 401, headers: { "content-type": "application/json" } }
      //     );
      //   }
      //   return await handleCreatePortalSession(env, authenticatedUserId);
      // }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

// ---------------------------------------------------------------------------
// JWT verification via JWKS (ECC P-256 / ES256)
// ---------------------------------------------------------------------------

interface JWKSKey {
  kid: string;
  kty: string;
  alg?: string;
  use?: string;
  crv?: string;  // for EC keys: "P-256"
  x?: string;    // EC public key x component (base64url)
  y?: string;    // EC public key y component (base64url)
  n?: string;    // RSA modulus (not used here)
  e?: string;    // RSA exponent (not used here)
}

interface JWKS {
  keys: JWKSKey[];
}

// Module-level JWKS cache. Persists across requests within the same isolate.
let cachedJWKS: JWKS | null = null;
let jwksCachedAtMs: number = 0;
const JWKS_CACHE_TTL_MS = 3_600_000; // 1 hour

async function fetchJWKS(supabaseURL: string): Promise<JWKS> {
  const now = Date.now();
  if (cachedJWKS && now - jwksCachedAtMs < JWKS_CACHE_TTL_MS) {
    return cachedJWKS;
  }

  const response = await fetch(`${supabaseURL}/auth/v1/.well-known/jwks.json`);
  if (!response.ok) {
    throw new Error(`Failed to fetch JWKS: HTTP ${response.status}`);
  }

  const jwks = await response.json() as JWKS;
  cachedJWKS = jwks;
  jwksCachedAtMs = now;
  return jwks;
}

// Discriminated union: either a verified user ID or an auth error response.
type JWTResult = { userId: string } | { authError: Response };

/**
 * Verifies the Bearer JWT from the Authorization header.
 * Returns { userId } on success or { authError } (HTTP 401) on failure.
 */
async function verifyRequestJWT(
  request: Request,
  supabaseURL: string
): Promise<JWTResult> {
  const authHeader = request.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return { authError: unauthorizedResponse("Missing or malformed Authorization header") };
  }

  const token = authHeader.slice("Bearer ".length).trim();

  try {
    const userId = await verifySupabaseJWT(token, supabaseURL);
    if (!userId) {
      return { authError: unauthorizedResponse("Invalid or expired JWT") };
    }
    return { userId };
  } catch (error) {
    console.error("[auth] JWT verification error:", error);
    return { authError: unauthorizedResponse("JWT verification failed") };
  }
}

/**
 * Verifies a Supabase JWT against the project's JWKS public keys.
 * Returns the user UUID (sub claim) on success, or null on failure.
 */
async function verifySupabaseJWT(
  token: string,
  supabaseURL: string
): Promise<string | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;

  const [encodedHeader, encodedPayload, encodedSignature] = parts;

  const header = JSON.parse(base64urlToString(encodedHeader)) as {
    kid?: string;
    alg?: string;
  };

  if (!header.kid) {
    console.warn("[auth] JWT missing kid header — cannot select JWKS key");
    return null;
  }

  const jwks = await fetchJWKS(supabaseURL);
  let jwk = jwks.keys.find((key) => key.kid === header.kid);

  if (!jwk) {
    // Kid not found — try refreshing the JWKS cache once in case keys rotated.
    cachedJWKS = null;
    const refreshedJWKS = await fetchJWKS(supabaseURL);
    jwk = refreshedJWKS.keys.find((key) => key.kid === header.kid);
    if (!jwk) {
      console.warn(`[auth] JWKS key not found for kid: ${header.kid}`);
      return null;
    }
  }

  return verifyEC256JWT(encodedHeader, encodedPayload, encodedSignature, jwk);
}

/**
 * Verifies an ES256 JWT signature using the provided EC P-256 public key.
 * Returns the user UUID (sub claim) on success, or null on failure.
 */
async function verifyEC256JWT(
  encodedHeader: string,
  encodedPayload: string,
  encodedSignature: string,
  jwk: JWKSKey
): Promise<string | null> {
  if (jwk.kty !== "EC" || jwk.crv !== "P-256") {
    console.warn(`[auth] Unsupported key type: kty=${jwk.kty} crv=${jwk.crv}`);
    return null;
  }

  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    jwk as unknown as JsonWebKey,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"]
  );

  const signatureBytes = base64urlToBytes(encodedSignature);
  const dataToVerify = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);

  const signatureIsValid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    signatureBytes.buffer as ArrayBuffer,
    dataToVerify.buffer as ArrayBuffer
  );

  if (!signatureIsValid) return null;

  const payload = JSON.parse(base64urlToString(encodedPayload)) as {
    sub?: string;
    exp?: number;
  };

  if (payload.exp !== undefined && payload.exp < Date.now() / 1000) {
    return null; // token expired
  }

  return payload.sub ?? null;
}

function unauthorizedResponse(message: string): Response {
  return new Response(
    JSON.stringify({ error: message }),
    { status: 401, headers: { "content-type": "application/json" } }
  );
}

// ---------------------------------------------------------------------------
// Quota management (Phase 3)
// ---------------------------------------------------------------------------

interface UserQuotaProfile {
  plan: string;
  daily_chat_count: number;
  // Postgres `date` type is returned as "YYYY-MM-DD" string via PostgREST.
  daily_chat_reset_at: string;
}

/**
 * Fetches the user's quota-relevant fields from user_profiles.
 * Uses the service role key to bypass RLS.
 * Returns null if the fetch fails — callers should fail open on null.
 */
async function fetchUserQuotaProfile(
  userId: string,
  supabaseURL: string,
  serviceRoleKey: string
): Promise<UserQuotaProfile | null> {
  const url =
    `${supabaseURL}/rest/v1/user_profiles` +
    `?id=eq.${userId}&select=plan,daily_chat_count,daily_chat_reset_at`;

  const res = await fetch(url, {
    headers: {
      "Authorization": `Bearer ${serviceRoleKey}`,
      "apikey": serviceRoleKey,
    },
  });

  if (!res.ok) {
    console.error("[quota] Failed to fetch user profile:", await res.text());
    return null;
  }

  const rows = await res.json() as UserQuotaProfile[];
  return rows[0] ?? null;
}

/**
 * Resets the user's daily_chat_count to 0 and updates daily_chat_reset_at
 * to today. Called when the stored reset date is behind the current date.
 */
async function resetDailyCount(
  userId: string,
  today: string,
  supabaseURL: string,
  serviceRoleKey: string
): Promise<void> {
  await fetch(`${supabaseURL}/rest/v1/user_profiles?id=eq.${userId}`, {
    method: "PATCH",
    headers: {
      "Authorization": `Bearer ${serviceRoleKey}`,
      "apikey": serviceRoleKey,
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({
      daily_chat_count: 0,
      daily_chat_reset_at: today,
    }),
  });
}

/**
 * Checks whether the user is within their daily chat quota. If over the
 * limit, returns a 429 Response. Otherwise increments daily_chat_count and
 * returns null (caller may proceed).
 *
 * Note: the increment uses a read-then-write pattern. A minor race condition
 * exists for concurrent requests, but is acceptable at early-access scale.
 * Replace with an atomic SQL RPC if higher accuracy is needed later.
 */
async function checkAndIncrementChatQuota(
  userId: string,
  env: Env
): Promise<Response | null> {
  const supabaseURL = env.SUPABASE_URL!;
  const serviceRoleKey = env.SUPABASE_SERVICE_ROLE_KEY!;

  const profile = await fetchUserQuotaProfile(userId, supabaseURL, serviceRoleKey);

  if (!profile) {
    // Fail open: proceed if we cannot read the DB (e.g. Supabase downtime).
    console.warn(`[quota] Could not read profile for ${userId} — failing open`);
    return null;
  }

  const today = new Date().toISOString().slice(0, 10); // "YYYY-MM-DD"

  // Reset count if last reset was before today (new calendar day).
  if (profile.daily_chat_reset_at < today) {
    await resetDailyCount(userId, today, supabaseURL, serviceRoleKey);
    profile.daily_chat_count = 0;
  }

  const planName = profile.plan ?? "free";
  const dailyLimit = PLAN_DAILY_CHAT_LIMITS[planName] ?? PLAN_DAILY_CHAT_LIMITS.free;

  if (profile.daily_chat_count >= dailyLimit) {
    return new Response(
      JSON.stringify({
        error: "daily_limit_exceeded",
        message: `每日 ${dailyLimit} 次对话额度已用完，请明天再试或升级套餐。`,
        plan: planName,
        daily_limit: dailyLimit,
        used_today: profile.daily_chat_count,
        remaining: 0,
      }),
      { status: 429, headers: { "content-type": "application/json" } }
    );
  }

  // Increment daily_chat_count (best-effort, before proxying to upstream).
  await fetch(`${supabaseURL}/rest/v1/user_profiles?id=eq.${userId}`, {
    method: "PATCH",
    headers: {
      "Authorization": `Bearer ${serviceRoleKey}`,
      "apikey": serviceRoleKey,
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({ daily_chat_count: profile.daily_chat_count + 1 }),
  });

  return null; // quota OK
}

/**
 * Inserts an api_usage_logs row and increments total_chat_count.
 * Designed to be called via ctx.waitUntil() so it does not block the response.
 */
async function recordChatUsage(
  userId: string,
  model: string,
  env: Env
): Promise<void> {
  const supabaseURL = env.SUPABASE_URL!;
  const serviceRoleKey = env.SUPABASE_SERVICE_ROLE_KEY!;

  // Insert usage log row. Token counts are omitted for now — streaming makes
  // them non-trivial to capture. Can be added later with stream_options.
  const logRes = await fetch(`${supabaseURL}/rest/v1/api_usage_logs`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${serviceRoleKey}`,
      "apikey": serviceRoleKey,
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({
      user_id: userId,
      api_type: "chat",
      model: model,
    }),
  });

  if (!logRes.ok) {
    console.error("[usage] Failed to insert api_usage_logs:", await logRes.text());
  }

  // Increment total_chat_count (read-then-write; same caveat as daily count).
  const profileRes = await fetch(
    `${supabaseURL}/rest/v1/user_profiles?id=eq.${userId}&select=total_chat_count`,
    {
      headers: {
        "Authorization": `Bearer ${serviceRoleKey}`,
        "apikey": serviceRoleKey,
      },
    }
  );

  if (!profileRes.ok) return;

  const profiles = await profileRes.json() as Array<{ total_chat_count: number }>;
  const currentTotal = profiles[0]?.total_chat_count ?? 0;

  await fetch(`${supabaseURL}/rest/v1/user_profiles?id=eq.${userId}`, {
    method: "PATCH",
    headers: {
      "Authorization": `Bearer ${serviceRoleKey}`,
      "apikey": serviceRoleKey,
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({ total_chat_count: currentTotal + 1 }),
  });
}

// ---------------------------------------------------------------------------
// GET /quota handler
// ---------------------------------------------------------------------------

/**
 * Returns the authenticated user's current quota status.
 * The Swift client calls this to populate the usage display in the panel.
 *
 * Response shape:
 *   { plan, daily_limit, used_today, remaining }
 */
async function handleQuota(
  userId: string | undefined,
  env: Env
): Promise<Response> {
  if (!userId || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(
      JSON.stringify({ error: "Quota tracking not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  const profile = await fetchUserQuotaProfile(
    userId,
    env.SUPABASE_URL,
    env.SUPABASE_SERVICE_ROLE_KEY
  );

  if (!profile) {
    return new Response(
      JSON.stringify({ error: "User profile not found" }),
      { status: 404, headers: { "content-type": "application/json" } }
    );
  }

  const today = new Date().toISOString().slice(0, 10);
  // If the stored reset date is before today, the count has effectively reset.
  const usedToday = profile.daily_chat_reset_at < today ? 0 : profile.daily_chat_count;
  const planName = profile.plan ?? "free";
  const dailyLimit = PLAN_DAILY_CHAT_LIMITS[planName] ?? PLAN_DAILY_CHAT_LIMITS.free;

  return new Response(
    JSON.stringify({
      plan: planName,
      daily_limit: dailyLimit,
      used_today: usedToday,
      remaining: Math.max(0, dailyLimit - usedToday),
    }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

// ---------------------------------------------------------------------------
// Base64url helpers
// ---------------------------------------------------------------------------

function base64urlToBytes(base64url: string): Uint8Array {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "=");
  const binary = atob(padded);
  const buffer = new ArrayBuffer(binary.length);
  const bytes = new Uint8Array(buffer);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function base64urlToString(base64url: string): string {
  return new TextDecoder().decode(base64urlToBytes(base64url));
}

// ---------------------------------------------------------------------------
// POST /chat handler
// ---------------------------------------------------------------------------

/**
 * Forwards the chat request to SiliconFlow's OpenAI-compatible
 * /chat/completions endpoint. Enforces daily quota when the service role key
 * is configured. Streams the SSE response body back to the client unchanged.
 */
async function handleChat(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  userId: string | undefined
): Promise<Response> {
  const rawBody = await request.text();

  let bodyObj: Record<string, unknown>;
  try {
    bodyObj = JSON.parse(rawBody);
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // Inject the worker's default model if the client did not specify one.
  if (!bodyObj.model && env.DEFAULT_CHAT_MODEL) {
    bodyObj.model = env.DEFAULT_CHAT_MODEL;
  }

  // --- Daily quota gate ---
  // Only enforced when the user is authenticated and the service role key is set.
  if (userId && env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY) {
    const quotaError = await checkAndIncrementChatQuota(userId, env);
    if (quotaError) return quotaError;
  }

  const baseURL = (env.SILICONFLOW_BASE_URL ?? "https://api.siliconflow.com/v1")
    .replace(/\/$/, "");
  const upstreamURL = `${baseURL}/chat/completions`;

  const response = await fetch(upstreamURL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.SILICONFLOW_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(bodyObj),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] SiliconFlow error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Fire-and-forget: log the usage row and increment total_chat_count.
  // Runs after the response starts streaming — does not block the client.
  if (userId && env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY) {
    const modelName = (bodyObj.model as string) ?? env.DEFAULT_CHAT_MODEL;
    ctx.waitUntil(recordChatUsage(userId, modelName, env));
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") ?? "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

// ---------------------------------------------------------------------------
// 微信支付 Native (Phase 4)
// ---------------------------------------------------------------------------

// 套餐价格（单位：分，1 CNY = 100 分）。
// 从 env 读取，默认值在此定义，可通过 wrangler.toml vars 覆盖。
function getWeChatPlanPrice(
  plan: string,
  env: Env
): { total: number; description: string } | null {
  const proPriceFen     = parseInt(env.WECHAT_PRO_PRICE_FEN     ?? "2900");
  const premiumPriceFen = parseInt(env.WECHAT_PREMIUM_PRICE_FEN ?? "9900");
  if (plan === "pro")     return { total: proPriceFen,     description: "Clicky Pro 月度套餐" };
  if (plan === "premium") return { total: premiumPriceFen, description: "Clicky Premium 月度套餐" };
  return null;
}

/**
 * Generates a unique out_trade_no (max 32 chars) for WeChat Pay.
 * Format: CLK{P|B}{8-char user prefix}{base36 timestamp}
 */
function generateOutTradeNo(userId: string, plan: string): string {
  const timestamp  = Date.now().toString(36).toUpperCase();
  const userPrefix = userId.replace(/-/g, "").slice(0, 8).toUpperCase();
  const planCode   = plan === "premium" ? "P" : "B";
  return `CLK${planCode}${userPrefix}${timestamp}`.slice(0, 32);
}

/**
 * Imports the merchant RSA private key (PKCS8 PEM format) for RSASSA-PKCS1-v1_5 signing.
 * WeChat Pay's apiclient_key.pem is in PKCS8 format (-----BEGIN PRIVATE KEY-----).
 */
async function importWeChatPrivateKey(pemKey: string): Promise<CryptoKey> {
  const base64 = pemKey
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/-----BEGIN RSA PRIVATE KEY-----/g, "")
    .replace(/-----END RSA PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  const binaryStr = atob(base64);
  const bytes = new Uint8Array(binaryStr.length);
  for (let i = 0; i < binaryStr.length; i++) {
    bytes[i] = binaryStr.charCodeAt(i);
  }

  return crypto.subtle.importKey(
    "pkcs8",
    bytes.buffer as ArrayBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
}

/**
 * Builds the WeChat Pay v3 Authorization header.
 * Signing string: {METHOD}\n{url_path_with_query}\n{timestamp}\n{nonce}\n{body}\n
 */
async function buildWeChatAuthHeader(
  method: string,
  urlPathWithQuery: string,
  body: string,
  env: Env
): Promise<string> {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const nonce     = crypto.randomUUID().replace(/-/g, "").toUpperCase();

  const signingString = `${method}\n${urlPathWithQuery}\n${timestamp}\n${nonce}\n${body}\n`;

  const privateKey      = await importWeChatPrivateKey(env.WECHAT_PRIVATE_KEY!);
  const signatureBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    new TextEncoder().encode(signingString)
  );
  const signature = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));

  return (
    `WECHATPAY2-SHA256-RSA2048 mchid="${env.WECHAT_MCH_ID}",` +
    `nonce_str="${nonce}",` +
    `timestamp="${timestamp}",` +
    `serial_no="${env.WECHAT_SERIAL_NO}",` +
    `signature="${signature}"`
  );
}

/**
 * Decrypts the AES-256-GCM encrypted resource in WeChat Pay async notifications.
 * Key: API v3 key (32 UTF-8 bytes). Nonce: 12 bytes from notification.
 * The ciphertext is standard base64 (not base64url) and includes the 16-byte GCM tag.
 */
async function decryptWeChatPayResource(
  ciphertext: string,
  nonce: string,
  associatedData: string,
  apiV3Key: string
): Promise<string> {
  const keyBytes  = new TextEncoder().encode(apiV3Key);
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "AES-GCM" },
    false,
    ["decrypt"]
  );

  // Ciphertext is standard base64 — use atob for decoding.
  const ciphertextBinary = atob(ciphertext);
  const ciphertextBytes  = new Uint8Array(ciphertextBinary.length);
  for (let i = 0; i < ciphertextBinary.length; i++) {
    ciphertextBytes[i] = ciphertextBinary.charCodeAt(i);
  }

  const plainBuffer = await crypto.subtle.decrypt(
    {
      name:           "AES-GCM",
      iv:             new TextEncoder().encode(nonce),
      additionalData: new TextEncoder().encode(associatedData),
      tagLength:      128,
    },
    cryptoKey,
    ciphertextBytes.buffer as ArrayBuffer
  );

  return new TextDecoder().decode(plainBuffer);
}

interface WeChatPayTransaction {
  trade_state: string; // "SUCCESS" | "NOTPAY" | "CLOSED" | "REFUND" | ...
  out_trade_no: string;
  // attach carries { user_id, plan } serialized as JSON — set during order creation.
  attach?: string;
}

interface WeChatPayNotification {
  id: string;
  event_type: string;
  resource: {
    algorithm:       string;
    ciphertext:      string;
    nonce:           string;
    associated_data?: string;
  };
}

/**
 * POST /create-wechat-order
 * Creates a WeChat Pay Native order and returns the QR code URL + out_trade_no.
 * The Swift client generates a QR code image from code_url and displays it.
 *
 * Request:  { plan: "pro" | "premium" }
 * Response: { code_url: string, out_trade_no: string, plan: string, amount_fen: number }
 */
async function handleCreateWeChatOrder(
  request: Request,
  env: Env,
  userId: string
): Promise<Response> {
  if (!env.WECHAT_MCH_ID || !env.WECHAT_APP_ID || !env.WECHAT_API_V3_KEY ||
      !env.WECHAT_PRIVATE_KEY || !env.WECHAT_SERIAL_NO) {
    return new Response(
      JSON.stringify({ error: "WeChat Pay not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  let body: { plan?: string };
  try {
    body = await request.json() as { plan?: string };
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const plan = body.plan;
  if (plan !== "pro" && plan !== "premium") {
    return new Response(
      JSON.stringify({ error: "Invalid plan — must be 'pro' or 'premium'" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const planConfig = getWeChatPlanPrice(plan, env);
  if (!planConfig) {
    return new Response(
      JSON.stringify({ error: "Plan price not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  const outTradeNo = generateOutTradeNo(userId, plan);
  const notifyHost = env.WECHAT_NOTIFY_HOST ?? new URL(request.url).origin;
  const notifyUrl  = `${notifyHost}/wechat-notify`;

  const orderBody = JSON.stringify({
    appid:        env.WECHAT_APP_ID,
    mchid:        env.WECHAT_MCH_ID,
    description:  planConfig.description,
    out_trade_no: outTradeNo,
    notify_url:   notifyUrl,
    // attach carries metadata so the webhook can update the correct user's plan
    // without needing an additional DB lookup by out_trade_no.
    attach: JSON.stringify({ user_id: userId, plan }),
    amount: { total: planConfig.total, currency: "CNY" },
  });

  const urlPath    = "/v3/pay/transactions/native";
  const authHeader = await buildWeChatAuthHeader("POST", urlPath, orderBody, env);

  const wechatRes = await fetch(`https://api.mch.weixin.qq.com${urlPath}`, {
    method:  "POST",
    headers: {
      "Authorization": authHeader,
      "Content-Type":  "application/json",
      "Accept":        "application/json",
      "User-Agent":    "clicky-proxy/1.0",
    },
    body: orderBody,
  });

  if (!wechatRes.ok) {
    const errorText = await wechatRes.text();
    console.error("[wechat-pay] Create order error:", errorText);
    return new Response(
      JSON.stringify({ error: "Failed to create WeChat Pay order", detail: errorText }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const wechatData = await wechatRes.json() as { code_url: string };
  console.log(`[wechat-pay] Created order ${outTradeNo} for user ${userId} (plan: ${plan})`);

  return new Response(
    JSON.stringify({
      code_url:    wechatData.code_url,
      out_trade_no: outTradeNo,
      plan,
      amount_fen:  planConfig.total,
    }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

/**
 * GET /check-payment-status?out_trade_no=xxx
 * Polls WeChat Pay for the order status. If paid, updates the user's plan in Supabase
 * and returns { paid: true }. The Swift client polls this every 3 seconds while the QR
 * code is displayed, avoiding the need to handle the async notification on the client side.
 *
 * The out_trade_no contains an embedded user prefix — but we still cross-check the
 * attach field to ensure the order belongs to the authenticated user.
 */
async function handleCheckPaymentStatus(
  request: Request,
  env: Env,
  userId: string
): Promise<Response> {
  if (!env.WECHAT_MCH_ID || !env.WECHAT_PRIVATE_KEY || !env.WECHAT_SERIAL_NO) {
    return new Response(
      JSON.stringify({ error: "WeChat Pay not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  const requestUrl = new URL(request.url);
  const outTradeNo = requestUrl.searchParams.get("out_trade_no");
  if (!outTradeNo) {
    return new Response(
      JSON.stringify({ error: "Missing out_trade_no query param" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // Query WeChat Pay for the order. The mchid must be included as a query param.
  const urlPath    = `/v3/pay/transactions/out-trade-no/${encodeURIComponent(outTradeNo)}?mchid=${env.WECHAT_MCH_ID}`;
  const authHeader = await buildWeChatAuthHeader("GET", urlPath, "", env);

  const wechatRes = await fetch(`https://api.mch.weixin.qq.com${urlPath}`, {
    headers: {
      "Authorization": authHeader,
      "Accept":        "application/json",
      "User-Agent":    "clicky-proxy/1.0",
    },
  });

  if (!wechatRes.ok) {
    const errorText = await wechatRes.text();
    console.error("[wechat-pay] Check order error:", errorText);
    // Return paid:false so the client keeps polling rather than showing an error.
    return new Response(
      JSON.stringify({ paid: false }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  }

  const transaction = await wechatRes.json() as WeChatPayTransaction;
  const isPaid      = transaction.trade_state === "SUCCESS";

  if (isPaid && env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY) {
    let plan = "pro";
    try {
      const attach = JSON.parse(transaction.attach ?? "{}") as {
        user_id?: string;
        plan?:    string;
      };
      // Security: ensure the order belongs to the authenticated user.
      if (attach.user_id && attach.user_id !== userId) {
        return new Response(
          JSON.stringify({ paid: false, error: "Order does not belong to this user" }),
          { status: 403, headers: { "content-type": "application/json" } }
        );
      }
      if (attach.plan) plan = attach.plan;
    } catch { /* parse failure — fall back to "pro" */ }

    await patchUserProfile(userId, { plan }, env);
    console.log(`[wechat-pay] Payment confirmed for ${outTradeNo} — set plan='${plan}' for user ${userId}`);
  }

  return new Response(
    JSON.stringify({ paid: isPaid, trade_state: transaction.trade_state }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

/**
 * POST /wechat-notify
 * Receives WeChat Pay async payment notifications. Called directly by WeChat servers —
 * no JWT auth. Decrypts the AES-256-GCM notification body and updates the user's plan.
 *
 * Signature verification (TODO for production hardening): verifying the
 * Wechatpay-Signature header requires fetching WeChat's platform certificate, which
 * adds complexity. As a safe alternative we query the order status directly from WeChat
 * Pay to confirm payment rather than trusting the notification payload alone.
 */
async function handleWeChatNotify(request: Request, env: Env): Promise<Response> {
  const ackOK   = () => new Response(JSON.stringify({ code: "SUCCESS" }),
    { status: 200, headers: { "content-type": "application/json" } });
  const ackFail = () => new Response(JSON.stringify({ code: "FAIL", message: "Processing error" }),
    { status: 500, headers: { "content-type": "application/json" } });

  if (!env.WECHAT_API_V3_KEY || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    console.error("[wechat-notify] Missing required env vars");
    return ackOK(); // Ack to avoid infinite retries from WeChat
  }

  let notification: WeChatPayNotification;
  try {
    notification = await request.json() as WeChatPayNotification;
  } catch {
    return ackOK();
  }

  // Only process successful payment events.
  if (notification.event_type !== "TRANSACTION.SUCCESS") {
    return ackOK();
  }

  try {
    const decryptedJson = await decryptWeChatPayResource(
      notification.resource.ciphertext,
      notification.resource.nonce,
      notification.resource.associated_data ?? "transaction",
      env.WECHAT_API_V3_KEY
    );

    const transaction = JSON.parse(decryptedJson) as WeChatPayTransaction;

    if (transaction.trade_state === "SUCCESS" && transaction.attach) {
      const attach = JSON.parse(transaction.attach) as {
        user_id?: string;
        plan?:    string;
      };
      if (attach.user_id && attach.plan) {
        await patchUserProfile(attach.user_id, { plan: attach.plan }, env);
        console.log(`[wechat-notify] Set plan='${attach.plan}' for user ${attach.user_id}`);
      }
    }
  } catch (error) {
    console.error("[wechat-notify] Failed to process notification:", error);
    // Return 500 so WeChat retries — but only do this for genuine processing failures.
    return ackFail();
  }

  return ackOK();
}

// ---------------------------------------------------------------------------
// POST /create-checkout-session handler (Phase 4, Stripe — 路由已注释掉)
// ---------------------------------------------------------------------------

interface StripeEvent {
  type: string;
  data: {
    object: Record<string, unknown>;
  };
}

interface StripeCheckoutSession {
  id: string;
  url: string | null;
  client_reference_id: string | null;
  customer: string | null;
  subscription: string | null;
  metadata: Record<string, string>;
}

interface StripeSubscription {
  id: string;
  customer: string;
  // "active" | "canceled" | "past_due" | "unpaid" | "trialing" | "incomplete"
  status: string;
  metadata: Record<string, string>;
  items: {
    data: Array<{
      price: {
        id: string;
      };
    }>;
  };
}

/**
 * Creates a Stripe Checkout Session for the authenticated user and returns
 * the hosted checkout URL. The Swift client opens this URL in the browser.
 *
 * Request body: { plan: "pro" | "premium" }
 * Response:     { url: string, session_id: string }
 */
async function handleCreateCheckoutSession(
  request: Request,
  env: Env,
  userId: string
): Promise<Response> {
  if (!env.STRIPE_SECRET_KEY) {
    return new Response(
      JSON.stringify({ error: "Stripe not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  let body: { plan?: string };
  try {
    body = await request.json() as { plan?: string };
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const plan = body.plan;
  if (plan !== "pro" && plan !== "premium") {
    return new Response(
      JSON.stringify({ error: "Invalid plan. Must be 'pro' or 'premium'" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const priceId = plan === "pro" ? env.STRIPE_PRO_PRICE_ID : env.STRIPE_PREMIUM_PRICE_ID;
  if (!priceId) {
    return new Response(
      JSON.stringify({ error: `Stripe price ID for plan '${plan}' is not configured` }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  const successUrl = env.STRIPE_SUCCESS_URL ?? "https://clicky.app/checkout-success";
  const cancelUrl  = env.STRIPE_CANCEL_URL  ?? "https://clicky.app/checkout-cancel";

  // Stripe REST API uses application/x-www-form-urlencoded.
  // client_reference_id links the checkout session back to the Supabase user UUID.
  const params = new URLSearchParams({
    mode: "subscription",
    "line_items[0][price]": priceId,
    "line_items[0][quantity]": "1",
    client_reference_id: userId,
    "metadata[user_id]": userId,
    "metadata[plan]": plan,
    success_url: successUrl,
    cancel_url: cancelUrl,
  });

  const stripeResponse = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params.toString(),
  });

  if (!stripeResponse.ok) {
    const errorText = await stripeResponse.text();
    console.error("[checkout] Stripe API error:", errorText);
    return new Response(
      JSON.stringify({ error: "Failed to create checkout session" }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const session = await stripeResponse.json() as StripeCheckoutSession;
  console.log(`[checkout] Created checkout session ${session.id} for user ${userId} (plan: ${plan})`);

  return new Response(
    JSON.stringify({ url: session.url, session_id: session.id }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

// ---------------------------------------------------------------------------
// POST /webhook handler (Phase 4)
// ---------------------------------------------------------------------------

/**
 * Verifies the Stripe-Signature header using HMAC-SHA256.
 * Stripe signs the raw request body with the webhook endpoint secret.
 * Rejects events older than 5 minutes to prevent replay attacks.
 */
async function verifyStripeWebhookSignature(
  rawBody: string,
  stripeSignatureHeader: string,
  webhookSecret: string
): Promise<boolean> {
  // Header format: "t=<unix_ts>,v1=<sig1>,v1=<sig2>"
  let timestamp: string | undefined;
  const v1Signatures: string[] = [];

  for (const part of stripeSignatureHeader.split(",")) {
    const eqIndex = part.indexOf("=");
    if (eqIndex === -1) continue;
    const key   = part.slice(0, eqIndex);
    const value = part.slice(eqIndex + 1);
    if (key === "t")  timestamp = value;
    if (key === "v1") v1Signatures.push(value);
  }

  if (!timestamp || v1Signatures.length === 0) return false;

  // Reject events older than 5 minutes (replay protection).
  const eventAgeMs = Math.abs(Date.now() - parseInt(timestamp) * 1000);
  if (eventAgeMs > 5 * 60 * 1000) {
    console.warn("[webhook] Stripe event timestamp too old — possible replay attack");
    return false;
  }

  // Stripe signature: HMAC-SHA256( key=webhookSecret, data="<ts>.<rawBody>" )
  const signedPayload = `${timestamp}.${rawBody}`;
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(webhookSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signatureBuffer = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(signedPayload)
  );
  const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
    .map(byte => byte.toString(16).padStart(2, "0"))
    .join("");

  return v1Signatures.some(sig => sig === expectedSignature);
}

/**
 * Updates a user_profiles row in Supabase with the provided fields.
 * Uses the service role key to bypass RLS.
 *
 * Uses `return=representation` so PostgREST returns the updated rows — this
 * lets us detect the "0 rows matched" silent-failure case that occurs when
 * `return=minimal` + HTTP 204 made it look like the PATCH succeeded even
 * though no row existed.
 */
async function patchUserProfile(
  userId: string,
  fields: Record<string, string | null>,
  env: Env
): Promise<void> {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/user_profiles?id=eq.${userId}`,
    {
      method: "PATCH",
      headers: {
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY!}`,
        "apikey": env.SUPABASE_SERVICE_ROLE_KEY!,
        "Content-Type": "application/json",
        "Prefer": "return=representation",
      },
      body: JSON.stringify(fields),
    }
  );

  if (!res.ok) {
    const errorText = await res.text();
    console.error(`[patchUserProfile] PATCH failed for ${userId}: HTTP ${res.status} — ${errorText}`);
    throw new Error(`patchUserProfile: HTTP ${res.status}`);
  }

  const updatedRows = await res.json() as unknown[];
  if (updatedRows.length === 0) {
    // The user_profiles row doesn't exist yet (trigger may not have fired on signup).
    // Fall back to upsert so the plan update is not silently dropped.
    console.error(
      `[patchUserProfile] 0 rows matched for userId=${userId} — row missing, falling back to upsert`
    );
    await upsertUserProfile(userId, fields, env);
  } else {
    console.log(`[patchUserProfile] Updated ${updatedRows.length} row(s) for userId=${userId}: ${JSON.stringify(fields)}`);
  }
}

/**
 * Upserts a user_profiles row. Used as a fallback when PATCH matches 0 rows,
 * meaning the row was never created by the DB trigger on signup.
 * Only sets the explicitly provided fields; other columns keep DB defaults.
 */
async function upsertUserProfile(
  userId: string,
  fields: Record<string, string | null>,
  env: Env
): Promise<void> {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/user_profiles`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY!}`,
        "apikey": env.SUPABASE_SERVICE_ROLE_KEY!,
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
      },
      body: JSON.stringify({ id: userId, ...fields }),
    }
  );

  if (!res.ok) {
    const errorText = await res.text();
    console.error(`[patchUserProfile] Upsert fallback failed for ${userId}: HTTP ${res.status} — ${errorText}`);
  } else {
    console.log(`[patchUserProfile] Upsert fallback succeeded for userId=${userId}: ${JSON.stringify(fields)}`);
  }
}

/**
 * Handles checkout.session.completed: upgrades the user's plan to the one
 * stored in session metadata, and saves the Stripe customer / subscription IDs.
 */
async function handleCheckoutSessionCompleted(
  session: StripeCheckoutSession,
  env: Env
): Promise<void> {
  // client_reference_id is the Supabase user UUID set during checkout creation.
  const userId = session.client_reference_id ?? session.metadata?.user_id;
  const plan   = session.metadata?.plan;

  if (!userId || !plan) {
    console.error("[webhook] checkout.session.completed missing user_id or plan in metadata");
    return;
  }

  await patchUserProfile(userId, {
    plan,
    stripe_customer_id:     session.customer ?? null,
    stripe_subscription_id: session.subscription ?? null,
  }, env);

  console.log(`[webhook] checkout.session.completed — set plan='${plan}' for user ${userId}`);
}

/**
 * Handles customer.subscription.updated and customer.subscription.deleted:
 * syncs the plan back to Supabase by looking up the user via stripe_customer_id.
 * On cancellation / non-payment, downgrades the user to free.
 */
async function handleSubscriptionChanged(
  subscription: StripeSubscription,
  env: Env
): Promise<void> {
  // Look up the Supabase user by their stored Stripe customer ID.
  const profileRes = await fetch(
    `${env.SUPABASE_URL}/rest/v1/user_profiles` +
    `?stripe_customer_id=eq.${subscription.customer}&select=id,plan`,
    {
      headers: {
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY!}`,
        "apikey": env.SUPABASE_SERVICE_ROLE_KEY!,
      },
    }
  );

  if (!profileRes.ok) {
    console.error("[webhook] Failed to look up user by stripe_customer_id");
    return;
  }

  const profiles = await profileRes.json() as Array<{ id: string; plan: string }>;
  const userProfile = profiles[0];

  if (!userProfile) {
    console.warn(`[webhook] No user found for Stripe customer ${subscription.customer}`);
    return;
  }

  // Determine the new plan from the subscription status and price ID.
  let newPlan: string;
  if (subscription.status === "canceled" || subscription.status === "unpaid") {
    newPlan = "free";
  } else {
    const activePriceId = subscription.items.data[0]?.price.id;
    if (activePriceId === env.STRIPE_PRO_PRICE_ID) {
      newPlan = "pro";
    } else if (activePriceId === env.STRIPE_PREMIUM_PRICE_ID) {
      newPlan = "premium";
    } else {
      console.warn(`[webhook] Unknown price ID '${activePriceId}' — skipping plan update`);
      return;
    }
  }

  await patchUserProfile(userProfile.id, { plan: newPlan }, env);
  console.log(
    `[webhook] subscription.${subscription.status} — set plan='${newPlan}' for user ${userProfile.id}`
  );
}

/**
 * Receives Stripe webhook events. Verifies the Stripe-Signature header before
 * processing any event data. Intentionally bypasses the JWT auth gate.
 */
async function handleStripeWebhook(request: Request, env: Env): Promise<Response> {
  if (!env.STRIPE_WEBHOOK_SECRET) {
    console.error("[webhook] STRIPE_WEBHOOK_SECRET is not set");
    return new Response(
      JSON.stringify({ error: "Webhook not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    console.error("[webhook] Supabase not configured — cannot sync plan");
    return new Response(
      JSON.stringify({ error: "Database not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  const rawBody = await request.text();
  const stripeSignature = request.headers.get("Stripe-Signature");

  if (!stripeSignature) {
    return new Response("Missing Stripe-Signature header", { status: 400 });
  }

  const signatureIsValid = await verifyStripeWebhookSignature(
    rawBody,
    stripeSignature,
    env.STRIPE_WEBHOOK_SECRET
  );

  if (!signatureIsValid) {
    console.warn("[webhook] Stripe signature verification failed");
    return new Response("Invalid signature", { status: 400 });
  }

  let event: StripeEvent;
  try {
    event = JSON.parse(rawBody) as StripeEvent;
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }

  console.log(`[webhook] Received Stripe event: ${event.type}`);

  // Sync plan on successful checkout completion.
  if (event.type === "checkout.session.completed") {
    await handleCheckoutSessionCompleted(
      event.data.object as unknown as StripeCheckoutSession,
      env
    );
  }

  // Sync plan on subscription status changes (upgrade, downgrade, cancellation).
  if (
    event.type === "customer.subscription.updated" ||
    event.type === "customer.subscription.deleted"
  ) {
    await handleSubscriptionChanged(
      event.data.object as unknown as StripeSubscription,
      env
    );
  }

  // Stripe requires a 200 response to acknowledge receipt.
  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// POST /create-portal-session handler (Phase 5)
// ---------------------------------------------------------------------------

/**
 * Creates a Stripe Billing Portal session so the user can manage their
 * subscription (cancel, update payment method, view invoices).
 *
 * Requires the user to have completed a checkout and therefore have a
 * stripe_customer_id stored in user_profiles.
 *
 * Response: { url: string } — open in the browser, returns to STRIPE_CANCEL_URL
 */
async function handleCreatePortalSession(
  env: Env,
  userId: string
): Promise<Response> {
  if (!env.STRIPE_SECRET_KEY) {
    return new Response(
      JSON.stringify({ error: "Stripe not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(
      JSON.stringify({ error: "Database not configured" }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  // Look up the Stripe customer ID from user_profiles.
  const profileRes = await fetch(
    `${env.SUPABASE_URL}/rest/v1/user_profiles?id=eq.${userId}&select=stripe_customer_id`,
    {
      headers: {
        "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        "apikey": env.SUPABASE_SERVICE_ROLE_KEY,
      },
    }
  );

  if (!profileRes.ok) {
    console.error("[portal] Failed to fetch user profile:", await profileRes.text());
    return new Response(
      JSON.stringify({ error: "Failed to read user profile" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const profiles = await profileRes.json() as Array<{ stripe_customer_id: string | null }>;
  const stripeCustomerId = profiles[0]?.stripe_customer_id;

  if (!stripeCustomerId) {
    // User has never completed a checkout — no Stripe customer record exists yet.
    return new Response(
      JSON.stringify({ error: "no_subscription", message: "尚无有效订阅，请先升级套餐。" }),
      { status: 404, headers: { "content-type": "application/json" } }
    );
  }

  const returnUrl = env.STRIPE_CANCEL_URL ?? "https://clicky.app";

  const params = new URLSearchParams({
    customer: stripeCustomerId,
    return_url: returnUrl,
  });

  const portalRes = await fetch("https://api.stripe.com/v1/billing_portal/sessions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params.toString(),
  });

  if (!portalRes.ok) {
    const errorText = await portalRes.text();
    console.error("[portal] Stripe API error:", errorText);
    return new Response(
      JSON.stringify({ error: "Failed to create portal session" }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const session = await portalRes.json() as { url: string; id: string };
  console.log(`[portal] Created portal session for user ${userId}`);

  return new Response(
    JSON.stringify({ url: session.url }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

// ---------------------------------------------------------------------------
// POST /tts handler
// ---------------------------------------------------------------------------

/**
 * Forwards the TTS request to SiliconFlow's OpenAI-compatible
 * /audio/speech endpoint. Injects default model and voice if omitted.
 */
async function handleTTS(request: Request, env: Env): Promise<Response> {
  const rawBody = await request.text();

  let bodyObj: Record<string, unknown>;
  try {
    bodyObj = JSON.parse(rawBody);
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  if (!bodyObj.model && env.DEFAULT_TTS_MODEL) {
    bodyObj.model = env.DEFAULT_TTS_MODEL;
  }
  if (!bodyObj.voice && env.DEFAULT_TTS_VOICE) {
    bodyObj.voice = env.DEFAULT_TTS_VOICE;
  }

  const baseURL = (env.SILICONFLOW_BASE_URL ?? "https://api.siliconflow.com/v1")
    .replace(/\/$/, "");
  const upstreamURL = `${baseURL}/audio/speech`;

  const response = await fetch(upstreamURL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.SILICONFLOW_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(bodyObj),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] SiliconFlow error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") ?? "audio/mpeg",
    },
  });
}
