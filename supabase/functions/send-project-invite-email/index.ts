import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const MAX_EMAILS_PER_10_MINUTES = 20;
const REFRESH_TOKEN_PREFIX = "enc:v1:";
const EMAIL_LOGO_URL = (
  Deno.env.get("EMAIL_LOGO_URL") ??
  "https://8answers.com/icons/Icon-192.png"
).trim();
const INVITE_BASE_URL = (
  Deno.env.get("INVITE_BASE_URL") ??
  Deno.env.get("APP_BASE_URL") ??
  "https://8answers.com/"
).trim();
const INVITE_PUBLIC_PAGE_URL = (
  Deno.env.get("INVITE_PUBLIC_PAGE_URL") ??
  ""
).trim();
const APP_DOWNLOAD_URL = (
  Deno.env.get("APP_DOWNLOAD_URL") ??
  "https://8answers.com/install/"
).trim();
const GMAIL_REAUTH_MESSAGE = [
  "Gmail authorization for this sender account expired or was not granted.",
  "Sign out and sign in with Google again, accept Gmail send permission, then retry.",
].join(" ");

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
  invitedEmail?: string;
  inviteToken?: string;
  directAuthUrl?: string;
  appDownloadUrl?: string;
  gmailRefreshToken?: string;
};

type GoogleTokenResponse = {
  access_token?: string;
  error?: string;
  error_description?: string;
};

type GoogleTokenExchangeResult = {
  accessToken?: string;
  error?: string;
  providerError?: string;
  providerErrorCode?: string;
  providerStatus?: number;
};

type GmailSendResponse = {
  id?: string;
  error?: {
    code?: number;
    message?: string;
    status?: string;
    errors?: Array<{
      domain?: string;
      message?: string;
      reason?: string;
    }>;
    details?: Array<{
      reason?: string;
    }>;
  };
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

function isLocalOrPrivateHost(hostname: string): boolean {
  const normalized = hostname.trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (!normalized) return true;

  if (
    normalized === "localhost" ||
    normalized === "127.0.0.1" ||
    normalized === "0.0.0.0" ||
    normalized === "::1" ||
    normalized.endsWith(".local")
  ) {
    return true;
  }

  const ipv4Parts = normalized.split(".");
  if (
    ipv4Parts.length === 4 &&
    ipv4Parts.every((part) => /^\d+$/.test(part))
  ) {
    const octets = ipv4Parts.map((part) => Number(part));
    if (octets.some((octet) => octet < 0 || octet > 255)) return true;
    if (octets[0] === 10) return true;
    if (octets[0] === 127) return true;
    if (octets[0] === 169 && octets[1] === 254) return true;
    if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    if (octets[0] === 192 && octets[1] === 168) return true;
  }

  return false;
}

function normalizeInviteUrl(value: string | undefined): string {
  const raw = (value ?? "").trim();
  if (!raw) return "";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "https:") return "";
    if (isLocalOrPrivateHost(parsed.hostname)) return "";
    if (parsed.hostname.trim().toLowerCase() === "www.8answers.com") {
      parsed.hostname = "8answers.com";
    }
    parsed.hash = "";
    return parsed.toString();
  } catch (_) {
    return "";
  }
}

function normalizeInviteBaseUrl(value: string | undefined): string {
  const raw = (value ?? "").trim();
  if (!raw) return "";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
      return "";
    }
    if (!parsed.hostname.trim()) return "";
    if (parsed.hostname.trim().toLowerCase() === "www.8answers.com") {
      parsed.hostname = "8answers.com";
    }
    if (!parsed.pathname || parsed.pathname.trim().length === 0) {
      parsed.pathname = "/";
    }
    if (!parsed.pathname.endsWith("/")) {
      parsed.pathname = `${parsed.pathname}/`;
    }
    parsed.search = "";
    parsed.hash = "";
    return parsed.toString();
  } catch (_) {
    return "";
  }
}

function buildResolveInviteFunctionUrl({
  supabaseUrl,
  inviteToken,
  projectId,
  projectRole,
  projectName,
  ownerEmail,
  invitedEmail,
}: {
  supabaseUrl: string;
  inviteToken: string;
  projectId: string;
  projectRole: string;
  projectName: string;
  ownerEmail: string;
  invitedEmail: string;
}): string {
  const normalized = (supabaseUrl ?? "").trim();
  if (!normalized) return "";
  try {
    const url = new URL(normalized);
    url.pathname = "/functions/v1/resolve-project-invite";
    url.search = "";
    url.hash = "";
    url.searchParams.set("invite", "1");
    url.searchParams.set("projectId", projectId);
    url.searchParams.set("projectRole", projectRole || "partner");
    if (inviteToken.trim()) url.searchParams.set("inv", inviteToken.trim());
    if (projectName.trim()) url.searchParams.set("projectName", projectName.trim());
    if (ownerEmail.trim()) url.searchParams.set("ownerEmail", ownerEmail.trim().toLowerCase());
    if (invitedEmail.trim()) {
      url.searchParams.set("invitedEmail", invitedEmail.trim().toLowerCase());
    }
    return url.toString();
  } catch (_) {
    return "";
  }
}

function buildHostedInvitePageUrl({
  baseUrl,
  inviteToken,
  projectId,
  projectRole,
  projectName,
  ownerEmail,
  invitedEmail,
}: {
  baseUrl: string;
  inviteToken: string;
  projectId: string;
  projectRole: string;
  projectName: string;
  ownerEmail: string;
  invitedEmail: string;
}): string {
  const normalized = (baseUrl ?? "").trim();
  if (!normalized) return "";
  try {
    const url = new URL(normalized);
    if (url.protocol !== "https:") return "";
    if (isLocalOrPrivateHost(url.hostname)) return "";
    if (url.hostname.trim().toLowerCase() === "www.8answers.com") {
      url.hostname = "8answers.com";
    }
    url.hash = "";
    url.searchParams.set("invite", "1");
    url.searchParams.set("projectId", projectId);
    url.searchParams.set("projectRole", projectRole || "partner");
    if (inviteToken.trim()) url.searchParams.set("inv", inviteToken.trim());
    if (projectName.trim()) url.searchParams.set("projectName", projectName.trim());
    if (ownerEmail.trim()) url.searchParams.set("ownerEmail", ownerEmail.trim().toLowerCase());
    if (invitedEmail.trim()) {
      url.searchParams.set("invitedEmail", invitedEmail.trim().toLowerCase());
    }
    return url.toString();
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
}): Promise<GoogleTokenExchangeResult> {
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
      const providerError = [
        data?.error,
        data?.error_description,
        `status_${response.status}`,
      ]
        .filter((value) => (value ?? "").trim().length > 0)
        .join(": ");
      return {
        error: "Failed to exchange Gmail refresh token",
        providerError,
        providerErrorCode: data?.error ?? "",
        providerStatus: response.status,
      };
    }

    return { accessToken: data.access_token };
  } catch (_) {
    return {
      error: "Failed to reach Google token endpoint",
    };
  }
}

function shouldRequireGoogleSenderReauth(
  exchanged: GoogleTokenExchangeResult,
): boolean {
  const providerCode = (exchanged.providerErrorCode ?? "")
    .trim()
    .toLowerCase();
  return exchanged.error === "Failed to exchange Gmail refresh token" &&
    (providerCode === "invalid_grant" || providerCode === "invalid_scope");
}

function getGmailFailureReason(data: GmailSendResponse | null): string {
  const legacyReason = (data?.error?.errors ?? [])
    .map((item) => (item.reason ?? "").trim().toLowerCase())
    .find((reason) => reason.length > 0);
  if (legacyReason) return legacyReason;

  const detailReason = (data?.error?.details ?? [])
    .map((item) => (item.reason ?? "").trim().toLowerCase())
    .find((reason) => reason.length > 0);
  if (detailReason) return detailReason;

  return (data?.error?.status ?? "").trim().toLowerCase();
}

function shouldRequireGoogleSenderReauthFromGmail(
  status: number,
  data: GmailSendResponse | null,
): boolean {
  if (status === 401) return true;
  if (status !== 403) return false;

  const reason = getGmailFailureReason(data);
  const message = (data?.error?.message ?? "").trim().toLowerCase();
  return reason === "insufficientpermissions" ||
    reason === "autherror" ||
    reason === "access_token_scope_insufficient" ||
    message.includes("insufficient authentication scopes");
}

async function clearStoredGoogleSenderToken(
  serviceClient: ReturnType<typeof createClient>,
  userId: string,
): Promise<void> {
  try {
    await serviceClient
      .from("user_mail_provider_tokens")
      .delete()
      .eq("user_id", userId)
      .eq("provider", "google");
  } catch (_) {
    // Best effort only. The client still receives a re-auth action.
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
  const inviteToken = (payload.inviteToken ?? "").trim();
  const directAuthUrl = normalizeInviteUrl(payload.directAuthUrl);
  const appDownloadUrl = normalizeInviteUrl(payload.appDownloadUrl);
  const projectName = sanitizeHeaderValue(payload.projectName, 200);
  const ownerEmail = normalizeEmail(payload.ownerEmail);
  const invitedEmail = normalizeEmail(payload.invitedEmail || to);
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
    if (shouldRequireGoogleSenderReauth(exchanged)) {
      await clearStoredGoogleSenderToken(serviceClient, user.id);
      return jsonResponse(400, {
        success: false,
        error: GMAIL_REAUTH_MESSAGE,
        action: "reauth_google_gmail",
        providerError: exchanged.providerError ?? "",
        providerStatus: exchanged.providerStatus ?? 0,
      }, requestOrigin);
    }
    return jsonResponse(502, {
      success: false,
      error: exchanged.error ?? "Failed to authorize Gmail sender",
      providerError: exchanged.providerError ?? "",
      providerStatus: exchanged.providerStatus ?? 0,
    }, requestOrigin);
  }

  const safeSubject = requestedSubject ||
    "You've been invited to access a project on 8Answers";
  const formattedRole = formatInviteRoleLabel(projectRole);
  const formattedProjectName = projectName || "Untitled Project";
  const functionInviteUrl = buildResolveInviteFunctionUrl({
    supabaseUrl,
    inviteToken,
    projectId,
    projectRole,
    projectName,
    ownerEmail,
    invitedEmail,
  });
  const hostedInvitePageUrl = buildHostedInvitePageUrl({
    baseUrl: INVITE_PUBLIC_PAGE_URL,
    inviteToken,
    projectId,
    projectRole,
    projectName,
    ownerEmail,
    invitedEmail,
  });
  const resolvedDirectAuthUrl =
    hostedInvitePageUrl ||
    directAuthUrl ||
    functionInviteUrl;
  const resolvedDownloadUrl = appDownloadUrl ||
    normalizeInviteUrl(APP_DOWNLOAD_URL) ||
    normalizeInviteBaseUrl(INVITE_BASE_URL);
  const inviteUrlRouteForLog = (() => {
    try {
      const parsed = new URL(resolvedDirectAuthUrl);
      return `${parsed.origin}${parsed.pathname}`;
    } catch (_) {
      return "";
    }
  })();
  console.info("invite_email_link_route", {
    route: inviteUrlRouteForLog,
    hasInviteTokenParam: resolvedDirectAuthUrl.includes("inv="),
    projectId,
    role: projectRole,
    recipient: to,
  });

  const safeLogoUrl = isLikelyHttpsUrl(EMAIL_LOGO_URL) ? EMAIL_LOGO_URL : "";
  const htmlBody = `<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; line-height: 1.6; color: #1a1a1a; margin: 0; padding: 0; background-color: #f4f7f9; }
        .wrapper { width: 100%; background-color: #f4f7f9; padding: 40px 0; }
        .container { max-width: 600px; margin: 0 auto; background-color: #ffffff; padding: 40px; border-radius: 8px; border: 1px solid #e1e8ed; }
        .logo-img {
            width: 44px;
            height: 44px;
            margin-bottom: 30px;
            display: block;
            border: 0;
            max-width: 100%;
        }
        .invite-card { background-color: #ffffff; border: 2px solid #0c8ce9; border-radius: 12px; padding: 30px; text-align: center; margin: 20px 0; }
        .project-label { font-size: 12px; color: #64748b; text-transform: uppercase; letter-spacing: 1px; font-weight: 700; margin-bottom: 5px; }
        .project-name { font-size: 24px; font-weight: 800; color: #000000; margin-bottom: 10px; }
        .role-badge { display: inline-block; padding: 4px 12px; background-color: #e0f2fe; color: #0c8ce9; border-radius: 100px; font-weight: 700; font-size: 13px; margin-bottom: 25px; }
        .button { display: inline-block; padding: 14px 40px; background-color: #0c8ce9; color: #ffffff !important; text-decoration: none; border-radius: 6px; font-weight: 600; width: 80%; box-sizing: border-box; }
        .setup-section { margin-top: 30px; padding: 0 10px; }
        .setup-title { font-size: 15px; font-weight: 700; color: #1e293b; margin-bottom: 8px; display: block; }
        .link { color: #0c8ce9; text-decoration: none; font-weight: 600; }
        .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #eee; font-size: 12px; color: #888; text-align: center; }
    </style>
</head>
<body>
    <div class="wrapper">
        <div class="container">
            ${safeLogoUrl
              ? `<img src="${escapeHtml(safeLogoUrl)}" width="44" height="44" alt="8Answers" class="logo-img">`
              : ""}
            <p>You've been invited to join a workspace on 8Answers.</p>

            <div class="invite-card">
                <div class="project-label">Project</div>
                <div class="project-name">${escapeHtml(formattedProjectName)}</div>
                <div class="role-badge">${escapeHtml(formattedRole)}</div>
                <br>
                ${resolvedDirectAuthUrl
                  ? `<a href="${escapeHtml(resolvedDirectAuthUrl)}" class="button">Accept Invitation</a>`
                  : ""}
            </div>

            <div class="setup-section">
                <span class="setup-title">New to 8Answers?</span>
                <p style="margin: 0; font-size: 14px; color: #475569;">
                    Please <a href="${escapeHtml(resolvedDownloadUrl || "https://8answers.com/install/")}" class="link">download the desktop app</a> first. Once installed, return to this email and click the button above to launch your project and set your password.
                </p>
            </div>

            <div class="footer">
                Copyright ©️ 2026 8Answers - All Rights Reserved.<br>
                This invite was intended for the project <strong>${escapeHtml(formattedProjectName)}</strong>.
            </div>
        </div>
    </div>
</body>
</html>`;

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
      | GmailSendResponse
      | null;

    if (!gmailResponse.ok) {
      if (
        shouldRequireGoogleSenderReauthFromGmail(
          gmailResponse.status,
          gmailData,
        )
      ) {
        await clearStoredGoogleSenderToken(serviceClient, user.id);
        return jsonResponse(400, {
          success: false,
          error: GMAIL_REAUTH_MESSAGE,
          action: "reauth_google_gmail",
          providerStatus: gmailResponse.status,
          providerError: getGmailFailureReason(gmailData),
        }, requestOrigin);
      }
      return jsonResponse(502, {
        success: false,
        error: "Gmail API rejected request",
        providerStatus: gmailResponse.status,
        providerError: getGmailFailureReason(gmailData),
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
      inviteUrlUsed: resolvedDirectAuthUrl,
    }, requestOrigin);
  } catch (_) {
    return jsonResponse(500, {
      success: false,
      error: "Failed to send invite email via Gmail",
    }, requestOrigin);
  }
});
