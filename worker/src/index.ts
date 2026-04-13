/**
 * Clicky Proxy Worker
 *
 * Proxies requests to SiliconFlow APIs so the app never ships with raw
 * API keys. The single SiliconFlow key is stored as a Cloudflare secret.
 *
 * Routes:
 *   POST /chat  → SiliconFlow /chat/completions (OpenAI-compatible, streaming)
 *   POST /tts   → SiliconFlow /audio/speech     (OpenAI-compatible TTS)
 *
 * Auth:
 *   When SUPABASE_URL is configured, all routes verify the Supabase JWT
 *   (ES256 / ECC P-256) from the Authorization header before proxying.
 *   Public keys are fetched from Supabase's JWKS endpoint and cached for 1 hour.
 *   If SUPABASE_URL is not set, auth is skipped (self-hosted / dev mode).
 */

interface Env {
  // Secret: SiliconFlow unified API key
  SILICONFLOW_API_KEY: string;
  // Vars (set in wrangler.toml)
  SILICONFLOW_BASE_URL: string;   // e.g. "https://api.siliconflow.cn/v1"
  DEFAULT_CHAT_MODEL: string;     // e.g. "Qwen/Qwen3.5-397B-A17B"
  DEFAULT_TTS_MODEL: string;      // e.g. "FunAudioLLM/CosyVoice2-0.5B"
  DEFAULT_TTS_VOICE: string;      // e.g. "FunAudioLLM/CosyVoice2-0.5B:alex"
  // When set, all routes require a valid Supabase JWT.
  SUPABASE_URL: string | undefined;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // --- Auth gate ---
    // Verifies the Supabase JWT when SUPABASE_URL is configured.
    if (env.SUPABASE_URL) {
      const authError = await verifyRequestJWT(request, env.SUPABASE_URL);
      if (authError) return authError;
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }
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

// Module-level JWKS cache. Cloudflare Workers have a per-isolate memory
// space, so this persists across requests within the same isolate lifetime.
let cachedJWKS: JWKS | null = null;
let jwksCachedAtMs: number = 0;
const JWKS_CACHE_TTL_MS = 3_600_000; // 1 hour

/**
 * Fetches and caches the Supabase JWKS (public key set).
 * Supabase exposes public keys at /auth/v1/.well-known/jwks.json.
 */
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

/**
 * Verifies the Bearer JWT from the Authorization header.
 * Returns a 401 Response if verification fails, or null if the token is valid.
 *
 * Supports ES256 (ECC P-256), which is the current Supabase default.
 */
async function verifyRequestJWT(
  request: Request,
  supabaseURL: string
): Promise<Response | null> {
  const authHeader = request.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return unauthorizedResponse("Missing or malformed Authorization header");
  }

  const token = authHeader.slice("Bearer ".length).trim();

  try {
    const isValid = await verifySupabaseJWT(token, supabaseURL);
    return isValid ? null : unauthorizedResponse("Invalid or expired JWT");
  } catch (error) {
    console.error("[auth] JWT verification error:", error);
    return unauthorizedResponse("JWT verification failed");
  }
}

/**
 * Verifies a Supabase JWT against the project's JWKS public keys.
 *
 * Flow:
 *   1. Decode the JWT header to get the key ID (kid).
 *   2. Fetch (or use cached) JWKS and find the matching key.
 *   3. Import the EC public key.
 *   4. Verify the ES256 signature.
 *   5. Check the exp claim.
 */
async function verifySupabaseJWT(
  token: string,
  supabaseURL: string
): Promise<boolean> {
  const parts = token.split(".");
  if (parts.length !== 3) return false;

  const [encodedHeader, encodedPayload, encodedSignature] = parts;

  // Decode the JWT header to identify which key to use.
  const header = JSON.parse(base64urlToString(encodedHeader)) as {
    kid?: string;
    alg?: string;
  };

  if (!header.kid) {
    console.warn("[auth] JWT missing kid header — cannot select JWKS key");
    return false;
  }

  // Look up the matching public key in JWKS.
  const jwks = await fetchJWKS(supabaseURL);
  const jwk = jwks.keys.find((key) => key.kid === header.kid);

  if (!jwk) {
    // Kid not found — try refreshing the cache once in case keys were rotated.
    cachedJWKS = null;
    const refreshedJWKS = await fetchJWKS(supabaseURL);
    const refreshedJwk = refreshedJWKS.keys.find((key) => key.kid === header.kid);
    if (!refreshedJwk) {
      console.warn(`[auth] JWKS key not found for kid: ${header.kid}`);
      return false;
    }
    return verifyEC256JWT(encodedHeader, encodedPayload, encodedSignature, refreshedJwk);
  }

  return verifyEC256JWT(encodedHeader, encodedPayload, encodedSignature, jwk);
}

/**
 * Verifies an ES256 JWT signature using the provided EC P-256 public key.
 * Also checks the exp claim.
 */
async function verifyEC256JWT(
  encodedHeader: string,
  encodedPayload: string,
  encodedSignature: string,
  jwk: JWKSKey
): Promise<boolean> {
  if (jwk.kty !== "EC" || jwk.crv !== "P-256") {
    console.warn(`[auth] Unsupported key type: kty=${jwk.kty} crv=${jwk.crv}`);
    return false;
  }

  // Import the EC P-256 public key from the JWK representation.
  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    // The Web Crypto JWK import accepts the key as a plain object with the
    // standard JWK fields (kty, crv, x, y). Cast to satisfy the type.
    jwk as unknown as JsonWebKey,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"]
  );

  // JWT ES256 signatures are raw R || S (64 bytes total, 32 per component).
  const signatureBytes = base64urlToBytes(encodedSignature);
  const dataToVerify = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);

  const signatureIsValid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    signatureBytes.buffer as ArrayBuffer,
    dataToVerify.buffer as ArrayBuffer
  );

  if (!signatureIsValid) return false;

  // Check the exp claim.
  const payload = JSON.parse(base64urlToString(encodedPayload)) as { exp?: number };
  if (payload.exp !== undefined && payload.exp < Date.now() / 1000) {
    return false; // token has expired
  }

  return true;
}

function unauthorizedResponse(message: string): Response {
  return new Response(
    JSON.stringify({ error: message }),
    { status: 401, headers: { "content-type": "application/json" } }
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
// Route handlers
// ---------------------------------------------------------------------------

/**
 * Forwards the chat request to SiliconFlow's OpenAI-compatible
 * /chat/completions endpoint. Injects DEFAULT_CHAT_MODEL if the client
 * did not specify one. Streams the response body back to the client.
 */
async function handleChat(request: Request, env: Env): Promise<Response> {
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

  // If the client did not specify a model, inject the worker default.
  if (!bodyObj.model && env.DEFAULT_CHAT_MODEL) {
    bodyObj.model = env.DEFAULT_CHAT_MODEL;
  }

  const baseURL = (env.SILICONFLOW_BASE_URL ?? "https://api.siliconflow.cn/v1")
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

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") ?? "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

/**
 * Forwards the TTS request to SiliconFlow's OpenAI-compatible
 * /audio/speech endpoint. Injects default model and voice if the client
 * did not specify them. Returns the audio binary stream.
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

  // Inject defaults for model and voice if the client omitted them.
  if (!bodyObj.model && env.DEFAULT_TTS_MODEL) {
    bodyObj.model = env.DEFAULT_TTS_MODEL;
  }
  if (!bodyObj.voice && env.DEFAULT_TTS_VOICE) {
    bodyObj.voice = env.DEFAULT_TTS_VOICE;
  }

  const baseURL = (env.SILICONFLOW_BASE_URL ?? "https://api.siliconflow.cn/v1")
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
