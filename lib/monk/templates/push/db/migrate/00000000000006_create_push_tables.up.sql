-- Monk::Push: one row per browser that allowed notifications
-- (docs/plan-pwa-push.md, B3). Each belongs to the auth session it was
-- made in, so notifications go only to devices where the person is
-- signed in: a session swept by Monk::Auth.sweep! takes its rows with it
-- (ON DELETE CASCADE), and a revoked one stops counting at once and is
-- cleared by Monk::Push.sweep!.
CREATE TABLE push_subscriptions (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id BIGINT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  -- The session's subject, copied so a person's subscriptions are one
  -- index lookup.
  subject TEXT NOT NULL,
  -- The push service's URL for this browser: a capability, never logged.
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  -- When the browser said the subscription ends (expirationTime), if it did.
  expires_at TIMESTAMPTZ,
  last_success_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX push_subscriptions_subject ON push_subscriptions (subject);
CREATE INDEX push_subscriptions_session_id ON push_subscriptions (session_id);
