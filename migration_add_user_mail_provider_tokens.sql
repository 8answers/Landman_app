-- Stores delegated mail provider refresh tokens per authenticated user.
-- Used by edge functions to send invite emails from each sender's own account.

CREATE TABLE IF NOT EXISTS public.user_mail_provider_tokens (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('google')),
  sender_email TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_user_mail_provider_tokens_user_id
  ON public.user_mail_provider_tokens(user_id);

ALTER TABLE public.user_mail_provider_tokens ENABLE ROW LEVEL SECURITY;

-- No client read/write policies by default.
-- Access is intentionally handled through edge functions using service role key.
