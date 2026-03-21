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

### Deploy

1. Link/auth your project:
   - `supabase login`
   - `supabase link --project-ref <your-project-ref>`

2. Set secrets:
   - `supabase secrets set SUPABASE_URL=https://<project-ref>.supabase.co`
   - `supabase secrets set SUPABASE_SERVICE_ROLE_KEY=...`
   - `supabase secrets set GOOGLE_OAUTH_CLIENT_ID=...`
   - `supabase secrets set GOOGLE_OAUTH_CLIENT_SECRET=...`

3. Deploy function:
   - `supabase functions deploy send-project-invite-email`

### Test

After deploy, sign out and sign in with Google once (with Gmail send scope), then
click `Send Request` in Settings.

If you get sender-token errors, sign out and sign in again with Google to refresh
consent and capture `provider_refresh_token`.
