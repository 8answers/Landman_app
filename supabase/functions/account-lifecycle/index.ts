import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const configuredAllowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((origin) => origin.trim())
  .filter((origin) => origin.length > 0);
const fallbackAllowedOrigin = (Deno.env.get("APP_BASE_URL") ?? "").trim();

type LifecyclePayload = {
  action?: string;
};

function getAllowedOrigin(requestOrigin: string): string {
  const origin = requestOrigin.trim();
  if (!origin) return "";

  if (configuredAllowedOrigins.length > 0) {
    if (
      configuredAllowedOrigins.includes("*") ||
      configuredAllowedOrigins.includes(origin)
    ) {
      return origin;
    }
    return "";
  }

  if (fallbackAllowedOrigin && origin === fallbackAllowedOrigin) {
    return origin;
  }

  return "";
}

function buildCorsHeaders(requestOrigin: string): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-supabase-auth, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
    "Vary": "Origin",
    "Cache-Control": "no-store",
  };
  const allowedOrigin = getAllowedOrigin(requestOrigin);
  headers["Access-Control-Allow-Origin"] = allowedOrigin || "*";
  return headers;
}

function jsonResponse(
  status: number,
  data: Record<string, unknown>,
  requestOrigin: string,
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: buildCorsHeaders(requestOrigin),
  });
}

function getBearerToken(req: Request): string {
  const possibleHeaders = [
    req.headers.get("authorization") ?? "",
    req.headers.get("x-supabase-auth") ?? "",
  ];

  for (const raw of possibleHeaders) {
    const trimmed = raw.trim();
    if (!trimmed) continue;

    if (trimmed.toLowerCase().startsWith("bearer ")) {
      const token = trimmed.slice(7).trim();
      // Ignore Supabase publishable/secret API keys accidentally sent as bearer.
      if (!token.startsWith("sb_publishable_") && !token.startsWith("sb_secret_")) {
        return token;
      }
      continue;
    }

    // Some clients may pass JWT directly without Bearer prefix.
    if (trimmed.split(".").length === 3) return trimmed;
  }

  return "";
}

Deno.serve(async (req: Request) => {
  const requestOrigin = req.headers.get("origin") ?? "";

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: buildCorsHeaders(requestOrigin) });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, {
      success: false,
      error: "Method not allowed",
    }, requestOrigin);
  }

  let payload: LifecyclePayload;
  try {
    payload = (await req.json()) as LifecyclePayload;
  } catch (_) {
    return jsonResponse(400, {
      success: false,
      error: "Invalid JSON payload",
    }, requestOrigin);
  }

  const action = (payload.action ?? "").trim().toLowerCase();
  if (action !== "delete_account") {
    return jsonResponse(400, {
      success: false,
      error: "Missing or invalid action",
    }, requestOrigin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return jsonResponse(500, {
      success: false,
      error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env",
    }, requestOrigin);
  }

  const userJwt = getBearerToken(req);
  if (!userJwt) {
    return jsonResponse(401, {
      success: false,
      error: "Missing bearer token",
    }, requestOrigin);
  }

  const serviceClient = createClient(supabaseUrl, supabaseServiceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  const userResult = await serviceClient.auth.getUser(userJwt);
  const user = userResult.data.user;
  if (!user || userResult.error) {
    return jsonResponse(401, {
      success: false,
      error: "Unauthorized user token",
    }, requestOrigin);
  }

  const deleteResult = await serviceClient.auth.admin.deleteUser(user.id);
  if (deleteResult.error) {
    return jsonResponse(500, {
      success: false,
      error: "Failed to delete account",
      details: deleteResult.error.message,
    }, requestOrigin);
  }

  return jsonResponse(200, {
    success: true,
    action: "delete_account",
    deleted: true,
  }, requestOrigin);
});
