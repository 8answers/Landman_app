import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const FALLBACK_REDIRECT_URL = (
  Deno.env.get("INVITE_FALLBACK_REDIRECT_URL") ??
  Deno.env.get("APP_BASE_URL") ??
  "https://8answers.com/"
).trim();

type InviteContext = {
  inviteToken?: string;
  projectId?: string;
  projectRole?: string;
  projectName?: string;
  ownerEmail?: string;
  invitedEmail?: string;
};

function buildCorsHeaders(origin: string): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin || "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Content-Type": "application/json",
    "Vary": "Origin",
    "Cache-Control": "no-store",
  };
}

function jsonResponse(
  status: number,
  payload: Record<string, unknown>,
  origin: string,
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: buildCorsHeaders(origin),
  });
}

function normalizeEmail(value: string | undefined): string {
  return (value ?? "").trim().toLowerCase();
}

function normalizeRole(value: string | undefined): string {
  switch ((value ?? "").trim().toLowerCase()) {
    case "partner":
    case "project_manager":
    case "agent":
    case "admin":
      return (value ?? "").trim().toLowerCase();
    default:
      return "";
  }
}

function formatRoleLabel(value: string): string {
  switch (value) {
    case "project_manager":
      return "Project Manager";
    case "partner":
      return "Partner";
    case "agent":
      return "Agent";
    case "admin":
      return "Admin";
    default:
      return "Partner";
  }
}

function decodeBase64Url(value: string): string {
  const normalized = (value ?? "").trim();
  if (!normalized) return "";
  const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
  const base64 = `${normalized}${padding}`
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  return decodeURIComponent(escape(atob(base64)));
}

function parseInviteToken(token: string): InviteContext {
  const rawToken = (token ?? "").trim();
  if (!rawToken) return {};
  try {
    const decoded = decodeBase64Url(rawToken);
    const parsed = JSON.parse(decoded);
    if (!parsed || typeof parsed !== "object") return {};
    return {
      projectId: String(parsed.projectId ?? "").trim(),
      projectRole: String(parsed.projectRole ?? "").trim(),
      projectName: String(parsed.projectName ?? "").trim(),
      ownerEmail: String(parsed.ownerEmail ?? "").trim(),
      invitedEmail: String(parsed.invitedEmail ?? "").trim(),
    };
  } catch (_) {
    return {};
  }
}

async function readInviteContext(req: Request): Promise<InviteContext> {
  if (req.method === "GET") {
    const url = new URL(req.url);
    return {
      inviteToken: url.searchParams.get("inv") ??
        url.searchParams.get("inviteToken") ??
        "",
      projectId: url.searchParams.get("projectId") ?? "",
      projectRole: url.searchParams.get("projectRole") ?? "",
      projectName: url.searchParams.get("projectName") ?? "",
      ownerEmail: url.searchParams.get("ownerEmail") ?? "",
      invitedEmail: url.searchParams.get("invitedEmail") ?? "",
    };
  }

  const body = await req.json().catch(() => ({}));
  return {
    inviteToken: String(body?.inviteToken ?? body?.inv ?? "").trim(),
    projectId: String(body?.projectId ?? "").trim(),
    projectRole: String(body?.projectRole ?? "").trim(),
    projectName: String(body?.projectName ?? "").trim(),
    ownerEmail: String(body?.ownerEmail ?? "").trim(),
    invitedEmail: String(body?.invitedEmail ?? "").trim(),
  };
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: buildCorsHeaders(origin),
    });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse(405, {
      success: false,
      error: "Method not allowed",
    }, origin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, {
      success: false,
      error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env",
    }, origin);
  }

  const rawContext = await readInviteContext(req);
  const tokenContext = parseInviteToken(rawContext.inviteToken ?? "");
  const projectId = (rawContext.projectId || tokenContext.projectId || "").trim();
  const projectRole = normalizeRole(
    rawContext.projectRole || tokenContext.projectRole,
  );
  const projectName = (rawContext.projectName || tokenContext.projectName || "")
    .trim();
  const ownerEmail = normalizeEmail(
    rawContext.ownerEmail || tokenContext.ownerEmail,
  );
  const invitedEmail = normalizeEmail(
    rawContext.invitedEmail || tokenContext.invitedEmail,
  );

  if (!projectId || !invitedEmail) {
    return jsonResponse(400, {
      success: false,
      error: "Missing invite context",
      redirectUrl: FALLBACK_REDIRECT_URL,
    }, origin);
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  const rpcResult = await serviceClient.rpc(
    "accept_project_invite_for_email",
    {
      p_project_id: projectId,
      p_invited_email: invitedEmail,
      p_role: projectRole || null,
    },
  );

  if (rpcResult.error) {
    return jsonResponse(500, {
      success: false,
      error: "Failed to resolve invite",
      details: rpcResult.error.message,
      redirectUrl: FALLBACK_REDIRECT_URL,
    }, origin);
  }

  const resultRow = Array.isArray(rpcResult.data) ? rpcResult.data[0] : null;
  const outcome = String(resultRow?.outcome ?? "").trim().toLowerCase();
  const resolvedRole = normalizeRole(
    String(resultRow?.role ?? projectRole).trim().toLowerCase(),
  );

  if (outcome === "missing_account") {
    return jsonResponse(200, {
      success: true,
      accepted: false,
      hasAccount: false,
      projectId,
      projectName,
      ownerEmail,
      invitedEmail,
      redirectUrl: FALLBACK_REDIRECT_URL,
    }, origin);
  }

  if (outcome === "accepted") {
    return jsonResponse(200, {
      success: true,
      accepted: true,
      hasAccount: true,
      projectId,
      projectName,
      ownerEmail,
      invitedEmail,
      role: resolvedRole || "partner",
      roleLabel: formatRoleLabel(resolvedRole || "partner"),
    }, origin);
  }

  const status = outcome || "invite_unavailable";
  const statusCode = status === "invite_not_found" ? 404 : 409;
  return jsonResponse(statusCode, {
    success: false,
    accepted: false,
    hasAccount: true,
    error: status === "invite_not_found"
      ? "Invitation not found."
      : "Invitation is no longer available.",
    projectId,
    projectName,
    ownerEmail,
    invitedEmail,
    role: resolvedRole || "partner",
    roleLabel: formatRoleLabel(resolvedRole || "partner"),
    redirectUrl: FALLBACK_REDIRECT_URL,
  }, origin);
});
