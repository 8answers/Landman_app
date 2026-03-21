import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

type InvitePayload = {
  to?: string;
  subject?: string;
  body?: string;
  projectId?: string;
  projectRole?: string;
  projectName?: string;
  ownerEmail?: string;
  directAuthUrl?: string;
  signInUrl?: string;
  gmailRefreshToken?: string;
};

type GoogleTokenResponse = {
  access_token?: string;
  error?: string;
  error_description?: string;
};

function jsonResponse(status: number, data: Record<string, unknown>): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: corsHeaders,
  });
}

function normalizeEmail(value: string | undefined): string {
  return (value ?? "").trim().toLowerCase();
}

function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function escapeHtml(input: string): string {
  return input
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function getBearerToken(req: Request): string {
  const authHeader = req.headers.get("authorization") ?? "";
  const trimmed = authHeader.trim();
  if (!trimmed.toLowerCase().startsWith("bearer ")) return "";
  return trimmed.slice(7).trim();
}

function toBase64Url(raw: string): string {
  return btoa(unescape(encodeURIComponent(raw)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function exchangeRefreshTokenForAccessToken(args: {
  refreshToken: string;
  googleClientId: string;
  googleClientSecret: string;
}): Promise<{ accessToken?: string; error?: string; details?: unknown }> {
  const form = new URLSearchParams({
    client_id: args.googleClientId,
    client_secret: args.googleClientSecret,
    refresh_token: args.refreshToken,
    grant_type: "refresh_token",
  });

  try {
    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });

    const data = (await response.json().catch(() => null)) as
      | GoogleTokenResponse
      | null;

    if (!response.ok || !data?.access_token) {
      return {
        error: "Failed to exchange Gmail refresh token",
        details: {
          status: response.status,
          response: data,
        },
      };
    }

    return { accessToken: data.access_token };
  } catch (error) {
    return {
      error: "Failed to reach Google token endpoint",
      details: error instanceof Error ? error.message : "unknown_error",
    };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, {
      success: false,
      error: "Method not allowed",
    });
  }

  let payload: InvitePayload;
  try {
    payload = (await req.json()) as InvitePayload;
  } catch (_) {
    return jsonResponse(400, {
      success: false,
      error: "Invalid JSON payload",
    });
  }

  const to = normalizeEmail(payload.to);
  if (!to || !isValidEmail(to)) {
    return jsonResponse(400, {
      success: false,
      error: "Missing or invalid recipient email",
    });
  }

  const subject = (payload.subject ?? "Project Access Request").trim();
  const textBody = (payload.body ?? "").trim();
  const directAuthUrl = (payload.directAuthUrl ?? "").trim();
  const signInUrl = (payload.signInUrl ?? "").trim();
  const projectRole = (payload.projectRole ?? "").trim();
  const projectName = (payload.projectName ?? "").trim();
  const payloadRefreshToken = (payload.gmailRefreshToken ?? "").trim();

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const googleClientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID") ?? "";
  const googleClientSecret = Deno.env.get("GOOGLE_OAUTH_CLIENT_SECRET") ?? "";

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return jsonResponse(500, {
      success: false,
      error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env",
    });
  }
  if (!googleClientId || !googleClientSecret) {
    return jsonResponse(500, {
      success: false,
      error: "Missing GOOGLE_OAUTH_CLIENT_ID or GOOGLE_OAUTH_CLIENT_SECRET env",
    });
  }

  const userJwt = getBearerToken(req);
  if (!userJwt) {
    return jsonResponse(401, {
      success: false,
      error: "Missing bearer token",
    });
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
      details: userResult.error?.message ?? null,
    });
  }

  const senderEmail = normalizeEmail(user.email ?? "");
  if (!senderEmail || !isValidEmail(senderEmail)) {
    return jsonResponse(400, {
      success: false,
      error: "Sender account does not have a valid email",
    });
  }

  if (payloadRefreshToken) {
    const upsertResult = await serviceClient
      .from("user_mail_provider_tokens")
      .upsert(
        {
          user_id: user.id,
          provider: "google",
          sender_email: senderEmail,
          refresh_token: payloadRefreshToken,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id,provider" },
      )
      .select("id")
      .limit(1);

    if (upsertResult.error) {
      return jsonResponse(500, {
        success: false,
        error: "Failed to store sender Gmail token",
        details: upsertResult.error.message,
      });
    }
  }

  const tokenResult = await serviceClient
    .from("user_mail_provider_tokens")
    .select("refresh_token, sender_email")
    .eq("user_id", user.id)
    .eq("provider", "google")
    .maybeSingle();

  if (tokenResult.error) {
    return jsonResponse(500, {
      success: false,
      error: "Failed to load sender Gmail token",
      details: tokenResult.error.message,
    });
  }

  const storedRefreshToken = (tokenResult.data?.refresh_token ?? "").toString().trim();
  const senderEmailFromToken = normalizeEmail(tokenResult.data?.sender_email ?? senderEmail);

  if (!storedRefreshToken) {
    return jsonResponse(400, {
      success: false,
      error:
        "No Gmail sender token found for this account. Sign out and sign in with Google again to grant Gmail send access.",
    });
  }

  const exchanged = await exchangeRefreshTokenForAccessToken({
    refreshToken: storedRefreshToken,
    googleClientId,
    googleClientSecret,
  });

  if (!exchanged.accessToken) {
    return jsonResponse(502, {
      success: false,
      error: exchanged.error ?? "Failed to authorize Gmail sender",
      details: exchanged.details ?? null,
    });
  }

  const htmlBody =
    `<div style="font-family: Arial, sans-serif; line-height: 1.5;">` +
    `<p>You have been invited to access this project${projectRole ? ` as <b>${escapeHtml(projectRole)}</b>` : ""}.</p>` +
    (projectName ? `<p><b>Project:</b> ${escapeHtml(projectName)}</p>` : "") +
    (directAuthUrl
      ? `<p><a href="${escapeHtml(directAuthUrl)}">Open project invite</a></p>`
      : "") +
    (signInUrl
      ? `<p>If needed, use sign-in link:<br/><a href="${escapeHtml(signInUrl)}">${escapeHtml(signInUrl)}</a></p>`
      : "") +
    (textBody
      ? `<hr/><pre style="white-space: pre-wrap;">${escapeHtml(textBody)}</pre>`
      : "") +
    `</div>`;

  const mime = [
    `From: ${senderEmailFromToken}`,
    `To: ${to}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    "Content-Type: text/html; charset=UTF-8",
    "",
    htmlBody,
  ].join("\r\n");

  try {
    const gmailResponse = await fetch(
      "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${exchanged.accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          raw: toBase64Url(mime),
        }),
      },
    );

    const gmailData = await gmailResponse.json().catch(() => null);

    if (!gmailResponse.ok) {
      return jsonResponse(502, {
        success: false,
        error: "Gmail API rejected request",
        providerStatus: gmailResponse.status,
        providerResponse: gmailData,
      });
    }

    return jsonResponse(200, {
      success: true,
      sent: true,
      provider: "gmail",
      senderEmail: senderEmailFromToken,
      providerResponse: gmailData,
    });
  } catch (error) {
    return jsonResponse(500, {
      success: false,
      error: "Failed to send invite email via Gmail",
      details: error instanceof Error ? error.message : "unknown_error",
    });
  }
});
