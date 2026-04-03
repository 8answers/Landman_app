## send-project-invite-email

Supabase Edge Function used by Settings -> `Send Request` to send invite emails
from the authenticated sender's own Gmail account (delegated OAuth flow).

### Google Cloud requirements

Use the same Google OAuth app that your Supabase Google sign-in already uses.

1. Enable `Gmail API` in Google Cloud Console:
   - APIs & Services -> Library -> `Gmail API` -> Enable
2. Ensure OAuth consent screen includes Gmail send scope:
   - `https://www.googleapis.com/auth/gmail.send`
3. Make sure your web app keeps requesting offline access + consent prompt,
   so Google returns `provider_refresh_token`.

### Required secrets

Set these for your Supabase project:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `GOOGLE_OAUTH_CLIENT_ID`
- `GOOGLE_OAUTH_CLIENT_SECRET`
- `MAIL_TOKEN_ENCRYPTION_KEY` (long random secret used to encrypt refresh tokens at rest)

### Optional security config

- `ALLOWED_ORIGINS` (comma-separated allowlist, e.g. `https://app.example.com,https://staging.example.com`)
- `APP_BASE_URL` (single fallback origin when `ALLOWED_ORIGINS` is not set)
- `INVITE_BASE_URL` (public invite-link base URL used when client payload has no valid HTTPS invite URL)
- `APP_DOWNLOAD_URL` (download/help page URL shown in invite emails)
- `EMAIL_LOGO_URL` (public `https://` image URL used in the footer logo)
  - Must return an image content-type (`image/png`, `image/jpeg`, or `image/svg+xml`)
  - Do not use private/authenticated URLs or local file paths

### Deploy

1. Link/auth your project:
   - `supabase login`
   - `supabase link --project-ref <your-project-ref>`

2. Set secrets:
   - `supabase secrets set SUPABASE_URL=https://<project-ref>.supabase.co`
   - `supabase secrets set SUPABASE_SERVICE_ROLE_KEY=...`
   - `supabase secrets set GOOGLE_OAUTH_CLIENT_ID=...`
   - `supabase secrets set GOOGLE_OAUTH_CLIENT_SECRET=...`
   - `supabase secrets set MAIL_TOKEN_ENCRYPTION_KEY=...`
   - `supabase secrets set ALLOWED_ORIGINS=https://<your-app-domain>`

3. Deploy function:
   - `supabase functions deploy send-project-invite-email`

4. Run the migration that creates `invite_email_audit` before using the function.

### Test

After deploy, sign out and sign in with Google once (with Gmail send scope), then
click `Send Request` in Settings.

If you get sender-token errors, sign out and sign in again with Google to refresh
consent and capture `provider_refresh_token`.
