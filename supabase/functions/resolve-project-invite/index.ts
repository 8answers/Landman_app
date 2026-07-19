import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const SIGN_IN_BASE_URL = (
  Deno.env.get("INVITE_SIGNIN_URL") ??
  Deno.env.get("APP_BASE_URL") ??
  "https://8answers.com/"
).trim();

const BRAND_LOGO_URL = (
  Deno.env.get("EMAIL_LOGO_URL") ??
  "https://8answers.com/icons/Icon-192.png"
).trim();

type InviteContext = {
  inviteToken?: string;
  projectId?: string;
  projectRole?: string;
  projectName?: string;
  ownerEmail?: string;
  invitedEmail?: string;
};

function buildJsonHeaders(origin: string): Record<string, string> {
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

function buildHtmlHeaders(origin: string): Headers {
  const headers = new Headers({
    "Access-Control-Allow-Origin": origin || "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  headers.set("Content-Type", "text/html; charset=UTF-8");
  return headers;
}

function jsonResponse(
  status: number,
  payload: Record<string, unknown>,
  origin: string,
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: buildJsonHeaders(origin),
  });
}

function htmlResponse(status: number, html: string, origin: string): Response {
  const body = new Blob([html], { type: "text/html; charset=UTF-8" });
  return new Response(body, {
    status,
    headers: buildHtmlHeaders(origin),
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

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
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

function normalizeHttpUrl(value: string): string {
  const raw = (value ?? "").trim();
  if (!raw) return "https://8answers.com/";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
      return "https://8answers.com/";
    }
    return parsed.toString();
  } catch (_) {
    return "https://8answers.com/";
  }
}

function buildSignInUrl({
  inviteToken,
  projectId,
  projectRole,
  projectName,
  ownerEmail,
  invitedEmail,
}: {
  inviteToken: string;
  projectId: string;
  projectRole: string;
  projectName: string;
  ownerEmail: string;
  invitedEmail: string;
}): string {
  const base = normalizeHttpUrl(SIGN_IN_BASE_URL);
  try {
    const url = new URL(base);
    url.searchParams.set("invite", "1");
    if (projectId.trim()) url.searchParams.set("projectId", projectId.trim());
    if (projectRole.trim()) url.searchParams.set("projectRole", projectRole.trim());
    if (inviteToken.trim()) url.searchParams.set("inv", inviteToken.trim());
    if (projectName.trim()) url.searchParams.set("projectName", projectName.trim());
    if (ownerEmail.trim()) url.searchParams.set("ownerEmail", ownerEmail.trim());
    if (invitedEmail.trim()) url.searchParams.set("invitedEmail", invitedEmail.trim());
    return url.toString();
  } catch (_) {
    return base;
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

function renderShell(content: string): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Invitation Status | 8Answers</title>
    <link
      href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700;800&display=swap"
      rel="stylesheet"
    />
    <style>
      body {
        font-family: "Inter", -apple-system, BlinkMacSystemFont, sans-serif;
        text-align: center;
        padding: 80px 20px;
        background-color: #f4f7f9;
        color: #1a1a1a;
        margin: 0;
        display: flex;
        justify-content: center;
        align-items: center;
        min-height: 80vh;
      }

      .card {
        max-width: 520px;
        width: 100%;
        background: #ffffff;
        padding: 40px;
        border-radius: 16px;
        box-shadow: 0 10px 25px rgba(0, 0, 0, 0.05);
        text-align: center;
      }

      .logo-img {
        height: 40px;
        width: auto;
        margin: 0 auto 30px auto;
        display: block;
      }

      h3 {
        font-size: 24px;
        font-weight: 800;
        color: #000000;
        margin: 0 0 16px 0;
        letter-spacing: -0.5px;
      }

      .instruction {
        font-size: 16px;
        color: #475569;
        line-height: 1.6;
        margin-bottom: 24px;
      }

      .success-badge {
        display: inline-block;
        background-color: #ecfdf5;
        color: #10b981;
        padding: 6px 16px;
        border-radius: 100px;
        font-weight: 700;
        font-size: 12px;
        text-transform: uppercase;
        margin-bottom: 20px;
      }

      .warning-badge {
        display: inline-block;
        background-color: #fff7ed;
        color: #c2410c;
        padding: 6px 16px;
        border-radius: 100px;
        font-weight: 700;
        font-size: 12px;
        text-transform: uppercase;
        margin-bottom: 20px;
      }

      .error-badge {
        display: inline-block;
        background-color: #fef2f2;
        color: #dc2626;
        padding: 6px 16px;
        border-radius: 100px;
        font-weight: 700;
        font-size: 12px;
        text-transform: uppercase;
        margin-bottom: 20px;
      }

      .action-steps {
        background-color: #f8fafc;
        padding: 24px;
        border-radius: 12px;
        border: 1px solid #e2e8f0;
        width: 100%;
        box-sizing: border-box;
      }

      .step-text {
        font-size: 15px;
        color: #1e293b;
        margin: 0;
        font-weight: 600;
        display: block;
      }

      .button-link {
        display: inline-block;
        padding: 12px 28px;
        border-radius: 8px;
        background-color: #0c8ce9;
        color: #ffffff;
        font-weight: 700;
        text-decoration: none;
        margin-top: 10px;
      }

      .help {
        font-size: 13px;
        color: #888888;
        margin-top: 32px;
        border-top: 1px solid #eeeeee;
        padding-top: 24px;
        line-height: 1.5;
      }

      .link {
        color: #0c8ce9;
        text-decoration: none;
        font-weight: 600;
      }
    </style>
  </head>
  <body>
    <div class="card">
      <img src="${escapeHtml(BRAND_LOGO_URL)}" alt="8Answers" class="logo-img" />
      ${content}
    </div>
  </body>
</html>`;
}

function renderAcceptedHtml(projectName: string, role: string): string {
  const safeProjectName = escapeHtml(projectName || "your project");
  const safeRoleLabel = escapeHtml(formatRoleLabel(role || "partner"));
  return renderShell(`
    <div class="success-badge">Access Confirmed</div>
    <h3>Invitation Accepted</h3>
    <p class="instruction">
      Your account is now linked to <strong>${safeProjectName}</strong> as <strong>${safeRoleLabel}</strong>.
    </p>
    <div class="action-steps">
      <span class="step-text">1. Open the 8Answers Desktop App</span>
      <div style="height: 12px;"></div>
      <span class="step-text">2. Check "Recent Projects" or "All Projects"</span>
    </div>
    <p style="font-size: 14px; color: #64748b; margin-top: 25px;">
      If the project doesn't appear immediately, refresh inside the app.
    </p>
    <div class="help">
      Need help? Contact
      <a href="mailto:connect@8answers.com" class="link">connect@8answers.com</a>
    </div>
  `);
}

function renderMissingAccountHtml(invitedEmail: string, signInUrl: string): string {
  const safeEmail = escapeHtml(invitedEmail);
  const safeSignInUrl = escapeHtml(signInUrl);
  return renderShell(`
    <div class="warning-badge">Action Required</div>
    <h3>Finish Sign-In To Accept</h3>
    <p class="instruction">
      We couldn't find an 8Answers account for <strong>${safeEmail}</strong>.
      Sign in or create an account with this email, then open the invite again.
    </p>
    <a href="${safeSignInUrl}" class="button-link">Continue to Sign In</a>
    <div class="help">
      Need help? Contact
      <a href="mailto:connect@8answers.com" class="link">connect@8answers.com</a>
    </div>
  `);
}

function renderErrorHtml(message: string, signInUrl: string): string {
  const safeMessage = escapeHtml(message);
  const safeSignInUrl = escapeHtml(signInUrl);
  return renderShell(`
    <div class="error-badge">Invite Error</div>
    <h3>We Couldn’t Confirm This Invitation</h3>
    <p class="instruction">${safeMessage}</p>
    <a href="${safeSignInUrl}" class="button-link">Go to 8Answers</a>
    <div class="help">
      Need help? Contact
      <a href="mailto:connect@8answers.com" class="link">connect@8answers.com</a>
    </div>
  `);
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: buildJsonHeaders(origin),
    });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse(405, {
      success: false,
      error: "Method not allowed",
    }, origin);
  }

  const rawContext = await readInviteContext(req);
  const tokenContext = parseInviteToken(rawContext.inviteToken ?? "");
  const inviteToken = (rawContext.inviteToken ?? "").trim();
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

  const signInUrl = buildSignInUrl({
    inviteToken,
    projectId,
    projectRole: projectRole || "partner",
    projectName,
    ownerEmail,
    invitedEmail,
  });

  if (!projectId || !invitedEmail) {
    if (req.method === "GET") {
      return htmlResponse(
        400,
        renderErrorHtml("Missing invite context. Please request a new invitation.", signInUrl),
        origin,
      );
    }
    return jsonResponse(400, {
      success: false,
      error: "Missing invite context",
      redirectUrl: signInUrl,
    }, origin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    if (req.method === "GET") {
      return htmlResponse(
        500,
        renderErrorHtml("Invite service is not configured. Please try again later.", signInUrl),
        origin,
      );
    }
    return jsonResponse(500, {
      success: false,
      error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env",
      redirectUrl: signInUrl,
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
    if (req.method === "GET") {
      return htmlResponse(
        500,
        renderErrorHtml("Failed to resolve invite. Please try again in a moment.", signInUrl),
        origin,
      );
    }
    return jsonResponse(500, {
      success: false,
      error: "Failed to resolve invite",
      details: rpcResult.error.message,
      redirectUrl: signInUrl,
    }, origin);
  }

  const resultRow = Array.isArray(rpcResult.data) ? rpcResult.data[0] : null;
  const outcome = String(resultRow?.outcome ?? "").trim().toLowerCase();
  const resolvedRole = normalizeRole(
    String(resultRow?.role ?? projectRole).trim().toLowerCase(),
  );

  if (outcome === "missing_account") {
    if (req.method === "GET") {
      return htmlResponse(200, renderMissingAccountHtml(invitedEmail, signInUrl), origin);
    }
    return jsonResponse(200, {
      success: true,
      accepted: false,
      hasAccount: false,
      projectId,
      projectName,
      ownerEmail,
      invitedEmail,
      redirectUrl: signInUrl,
    }, origin);
  }

  if (outcome === "accepted") {
    if (req.method === "GET") {
      return htmlResponse(
        200,
        renderAcceptedHtml(projectName, resolvedRole || "partner"),
        origin,
      );
    }
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
  const statusMessage = status === "invite_not_found"
    ? "Invitation not found."
    : "Invitation is no longer available.";

  if (req.method === "GET") {
    return htmlResponse(statusCode, renderErrorHtml(statusMessage, signInUrl), origin);
  }

  return jsonResponse(statusCode, {
    success: false,
    accepted: false,
    hasAccount: true,
    error: statusMessage,
    projectId,
    projectName,
    ownerEmail,
    invitedEmail,
    role: resolvedRole || "partner",
    roleLabel: formatRoleLabel(resolvedRole || "partner"),
    redirectUrl: signInUrl,
  }, origin);
});
