import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const MAX_EMAILS_PER_10_MINUTES = 20;
const REFRESH_TOKEN_PREFIX = "enc:v1:";
const EMAIL_LOGO_URL = (
  Deno.env.get("EMAIL_LOGO_URL") ??
  "https://8answers.com/assets/assets/images/8answers.svg"
).trim();

const configuredAllowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((origin) => origin.trim())
  .filter((origin) => origin.length > 0);
const fallbackAllowedOrigin = (Deno.env.get("APP_BASE_URL") ?? "").trim();

let cachedTokenCryptoKey: CryptoKey | null = null;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

type InvitePayload = {
  to?: string;
  subject?: string;
  body?: string;
  projectId?: string;
  projectRole?: string;
  projectName?: string;
  ownerEmail?: string;
  directAuthUrl?: string;
  gmailRefreshToken?: string;
};

type GoogleTokenResponse = {
  access_token?: string;
  error?: string;
  error_description?: string;
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
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
    "Vary": "Origin",
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

function normalizeEmail(value: string | undefined): string {
  return (value ?? "").trim().toLowerCase();
}

function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function normalizeInviteRole(value: string | undefined): string {
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

function formatInviteRoleLabel(value: string): string {
  switch ((value ?? "").trim().toLowerCase()) {
    case "project_manager":
      return "Project Manager";
    case "partner":
      return "Partner";
    case "agent":
      return "Agent";
    case "admin":
      return "Admin";
    default:
      return value || "Not specified";
  }
}

function sanitizeHeaderValue(value: string | undefined, maxLength: number): string {
  return (value ?? "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

function normalizeInviteUrl(value: string | undefined): string {
  const raw = (value ?? "").trim();
  if (!raw) return "";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol === "https:") return parsed.toString();
    if (
      parsed.protocol === "http:" &&
      (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1")
    ) {
      return parsed.toString();
    }
    return "";
  } catch (_) {
    return "";
  }
}

function escapeHtml(input: string): string {
  return input
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function isLikelyHttpsUrl(value: string): boolean {
  return /^https:\/\/[^\s]+$/i.test((value ?? "").trim());
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

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function getTokenCryptoKey(secret: string): Promise<CryptoKey> {
  if (cachedTokenCryptoKey) return cachedTokenCryptoKey;
  const secretHash = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  cachedTokenCryptoKey = await crypto.subtle.importKey(
    "raw",
    secretHash,
    { name: "AES-GCM" },
    false,
    ["encrypt", "decrypt"],
  );
  return cachedTokenCryptoKey;
}

async function encryptRefreshToken(
  token: string,
  secret: string,
): Promise<string> {
  const key = await getTokenCryptoKey(secret);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    encoder.encode(token),
  );
  const payload = bytesToBase64(new Uint8Array(encrypted));
  return `${REFRESH_TOKEN_PREFIX}${bytesToBase64(iv)}.${payload}`;
}

async function decryptRefreshToken(
  storedValue: string,
  secret: string,
): Promise<string> {
  const trimmed = storedValue.trim();
  if (!trimmed) return "";
  if (!trimmed.startsWith(REFRESH_TOKEN_PREFIX)) {
    // Backward compatibility for legacy plaintext rows.
    return trimmed;
  }

  const encoded = trimmed.slice(REFRESH_TOKEN_PREFIX.length);
  const splitIndex = encoded.indexOf(".");
  if (splitIndex <= 0 || splitIndex >= encoded.length - 1) {
    throw new Error("invalid_encrypted_token_format");
  }
  const ivEncoded = encoded.slice(0, splitIndex);
  const payloadEncoded = encoded.slice(splitIndex + 1);

  const iv = base64ToBytes(ivEncoded);
  const payload = base64ToBytes(payloadEncoded);
  const key = await getTokenCryptoKey(secret);

  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv },
    key,
    payload,
  );
  return decoder.decode(decrypted).trim();
}

async function exchangeRefreshTokenForAccessToken(args: {
  refreshToken: string;
  googleClientId: string;
  googleClientSecret: string;
}): Promise<{ accessToken?: string; error?: string }> {
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
      };
    }

    return { accessToken: data.access_token };
  } catch (_) {
    return {
      error: "Failed to reach Google token endpoint",
    };
  }
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

  let payload: InvitePayload;
  try {
    payload = (await req.json()) as InvitePayload;
  } catch (_) {
    return jsonResponse(400, {
      success: false,
      error: "Invalid JSON payload",
    }, requestOrigin);
  }

  const to = normalizeEmail(payload.to);
  if (!to || !isValidEmail(to)) {
    return jsonResponse(400, {
      success: false,
      error: "Missing or invalid recipient email",
    }, requestOrigin);
  }

  const projectId = (payload.projectId ?? "").trim();
  const projectRole = normalizeInviteRole(payload.projectRole);
  if (!projectId || !projectRole) {
    return jsonResponse(400, {
      success: false,
      error: "Missing or invalid project context",
    }, requestOrigin);
  }

  const requestedSubject = sanitizeHeaderValue(payload.subject, 180);
  const directAuthUrl = normalizeInviteUrl(payload.directAuthUrl);
  const projectName = sanitizeHeaderValue(payload.projectName, 200);
  const payloadRefreshToken = (payload.gmailRefreshToken ?? "").trim();

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const googleClientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID") ?? "";
  const googleClientSecret = Deno.env.get("GOOGLE_OAUTH_CLIENT_SECRET") ?? "";
  const mailTokenEncryptionKey =
    Deno.env.get("MAIL_TOKEN_ENCRYPTION_KEY") ?? "";

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return jsonResponse(500, {
      success: false,
      error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env",
    }, requestOrigin);
  }
  if (!googleClientId || !googleClientSecret) {
    return jsonResponse(500, {
      success: false,
      error: "Missing GOOGLE_OAUTH_CLIENT_ID or GOOGLE_OAUTH_CLIENT_SECRET env",
    }, requestOrigin);
  }
  const hasMailTokenEncryptionKey = mailTokenEncryptionKey.trim().length > 0;

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

  const senderEmail = normalizeEmail(user.email ?? "");
  if (!senderEmail || !isValidEmail(senderEmail)) {
    return jsonResponse(400, {
      success: false,
      error: "Sender account does not have a valid email",
    }, requestOrigin);
  }

  const projectRow = await serviceClient
    .from("projects")
    .select("id, user_id")
    .eq("id", projectId)
    .maybeSingle();

  if (projectRow.error || !projectRow.data) {
    return jsonResponse(403, {
      success: false,
      error: "Project not found or inaccessible",
    }, requestOrigin);
  }

  const isOwner = ((projectRow.data.user_id ?? "").toString().trim() === user.id);
  if (!isOwner) {
    const roleRow = await serviceClient
      .from("project_members")
      .select("role, status")
      .eq("project_id", projectId)
      .eq("user_id", user.id)
      .limit(1)
      .maybeSingle();

    const memberRole = (roleRow.data?.role ?? "").toString().trim().toLowerCase();
    const memberStatus =
      (roleRow.data?.status ?? "").toString().trim().toLowerCase();
    const canSend =
      !roleRow.error &&
      memberStatus == "active" &&
      (memberRole == "admin" || memberRole == "project_manager");

    if (!canSend) {
      return jsonResponse(403, {
        success: false,
        error: "You do not have permission to send invites for this project",
      }, requestOrigin);
    }
  }

  const inviteRow = await serviceClient
    .from("project_access_invites")
    .select("id, status")
    .eq("project_id", projectId)
    .eq("invited_email", to)
    .eq("role", projectRole)
    .order("requested_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (inviteRow.error || !inviteRow.data) {
    return jsonResponse(403, {
      success: false,
      error: "Invite row not found for this recipient/role",
    }, requestOrigin);
  }

  const inviteStatus = (inviteRow.data.status ?? "").toString().trim().toLowerCase();
  if (inviteStatus === "revoked" || inviteStatus === "expired") {
    return jsonResponse(400, {
      success: false,
      error: "Invite is no longer active",
    }, requestOrigin);
  }

  const tenMinutesAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const recentSendCount = await serviceClient
    .from("invite_email_audit")
    .select("id", { count: "exact", head: true })
    .eq("user_id", user.id)
    .gte("sent_at", tenMinutesAgo);

  if (recentSendCount.error) {
    // Best effort only: keep invite sending functional even if audit table/migration is missing.
    console.warn(
      "invite_email_audit unavailable; skipping rate-limit check",
      recentSendCount.error.message,
    );
  } else if ((recentSendCount.count ?? 0) >= MAX_EMAILS_PER_10_MINUTES) {
    return jsonResponse(429, {
      success: false,
      error: "Rate limit exceeded. Please wait before sending more invites.",
    }, requestOrigin);
  }

  if (payloadRefreshToken) {
    let storedRefreshTokenValue = payloadRefreshToken;
    if (hasMailTokenEncryptionKey) {
      try {
        storedRefreshTokenValue = await encryptRefreshToken(
          payloadRefreshToken,
          mailTokenEncryptionKey,
        );
      } catch (_) {
        return jsonResponse(500, {
          success: false,
          error: "Failed to encrypt Gmail sender token",
        }, requestOrigin);
      }
    }

    const upsertResult = await serviceClient
      .from("user_mail_provider_tokens")
      .upsert(
        {
          user_id: user.id,
          provider: "google",
          sender_email: senderEmail,
          refresh_token: storedRefreshTokenValue,
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
      }, requestOrigin);
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
    }, requestOrigin);
  }

  const storedRefreshToken =
    (tokenResult.data?.refresh_token ?? "").toString().trim();
  const senderEmailFromToken =
    normalizeEmail(tokenResult.data?.sender_email ?? senderEmail);

  if (!storedRefreshToken) {
    return jsonResponse(400, {
      success: false,
      error:
        "No Gmail sender token found for this account. Sign out and sign in with Google again to grant Gmail send access.",
    }, requestOrigin);
  }

  let decryptedRefreshToken = "";
  try {
    if (storedRefreshToken.startsWith(REFRESH_TOKEN_PREFIX)) {
      if (!hasMailTokenEncryptionKey) {
        return jsonResponse(500, {
          success: false,
          error:
            "Stored Gmail token is encrypted but MAIL_TOKEN_ENCRYPTION_KEY is missing",
        }, requestOrigin);
      }
      decryptedRefreshToken = await decryptRefreshToken(
        storedRefreshToken,
        mailTokenEncryptionKey,
      );
    } else {
      decryptedRefreshToken = storedRefreshToken;
    }
  } catch (_) {
    return jsonResponse(500, {
      success: false,
      error: "Stored Gmail sender token could not be decrypted",
    }, requestOrigin);
  }

  if (!decryptedRefreshToken) {
    return jsonResponse(400, {
      success: false,
      error:
        "No Gmail sender token found for this account. Sign out and sign in with Google again to grant Gmail send access.",
    }, requestOrigin);
  }

  const exchanged = await exchangeRefreshTokenForAccessToken({
    refreshToken: decryptedRefreshToken,
    googleClientId,
    googleClientSecret,
  });

  if (!exchanged.accessToken) {
    return jsonResponse(502, {
      success: false,
      error: exchanged.error ?? "Failed to authorize Gmail sender",
    }, requestOrigin);
  }

  const safeSubject = requestedSubject ||
    "You've been invited to access a project on 8Answers";
  const formattedRole = formatInviteRoleLabel(projectRole);
  const formattedProjectName = projectName || "Not specified";

  const safeLogoUrl = isLikelyHttpsUrl(EMAIL_LOGO_URL) ? EMAIL_LOGO_URL : "";
  const htmlBody =
    `<div style="font-family: Arial, sans-serif; line-height: 1.6; color: #111111;">` +
    `<p>Hello,</p>` +
    `<p>You have been invited to access a project on 8Answers.</p>` +
    `<p><b>Project:</b> ${escapeHtml(formattedProjectName)}<br/>` +
    `<b>Assigned Role:</b> ${escapeHtml(formattedRole)}</p>` +
    (directAuthUrl
      ? `<p>To get started, click the link below:<br/>` +
        `<a href="${escapeHtml(directAuthUrl)}" style="color: #0C8CE9; text-decoration: none;">` +
        `&#128073; ${escapeHtml(directAuthUrl)}</a></p>`
      : "") +
    `<p>This link will take you to sign in and redirect you directly to the project.</p>` +
    `<p>If you did not expect this invitation, please ignore this email.</p>` +
    `<div style="margin-top: 20px; padding-top: 14px; border-top: 1px solid #E5E7EB;">` +
    (safeLogoUrl
      ? `<img src="${escapeHtml(safeLogoUrl)}" alt="8Answers" width="110" height="22" style="display: block; margin-bottom: 8px;" />`
      : "") +
    `<div style="font-size: 14px; color: #111111;">connect@8answers.com</div>` +
    `<div style="font-size: 14px; color: #111111;">www.8answers.com</div>` +
    `</div>` +
    `</div>`;

  const mime = [
    `From: ${sanitizeHeaderValue(senderEmailFromToken, 254)}`,
    `To: ${sanitizeHeaderValue(to, 254)}`,
    `Subject: ${safeSubject}`,
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

    const gmailData = await gmailResponse.json().catch(() => null) as
      | { id?: string }
      | null;

    if (!gmailResponse.ok) {
      return jsonResponse(502, {
        success: false,
        error: "Gmail API rejected request",
        providerStatus: gmailResponse.status,
      }, requestOrigin);
    }

    await serviceClient.from("invite_email_audit").insert({
      user_id: user.id,
      project_id: projectId,
      invited_email: to,
      role: projectRole,
      sent_at: new Date().toISOString(),
    });

    return jsonResponse(200, {
      success: true,
      sent: true,
      provider: "gmail",
      senderEmail: senderEmailFromToken,
      providerMessageId: (gmailData?.id ?? "").toString(),
    }, requestOrigin);
  } catch (_) {
    return jsonResponse(500, {
      success: false,
      error: "Failed to send invite email via Gmail",
    }, requestOrigin);
  }
});
