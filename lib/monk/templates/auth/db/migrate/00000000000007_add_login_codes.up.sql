-- Monk::Auth's sign-in code (Monk 0.28): a 6-digit code beside the magic
-- link, redeeming the same login token (Monk::Auth.redeem_code).

-- An HMAC of the code, keyed by AUTH_SECRET (six digits are trivial to
-- try offline from a plain hash), and the wrong guesses at it: the fifth
-- uses the token up.
ALTER TABLE login_tokens ADD COLUMN code_hash TEXT;
ALTER TABLE login_tokens ADD COLUMN code_attempts INTEGER NOT NULL DEFAULT 0;

-- redeem_code checks an address's newest token.
CREATE INDEX login_tokens_email_created_at ON login_tokens (email, created_at);

-- Wrong codes per address, across its tokens: past 10 in an hour,
-- redeem_code refuses the address until the hour is up.
ALTER TABLE login_requests ADD COLUMN code_failures INTEGER NOT NULL DEFAULT 0;
ALTER TABLE login_requests ADD COLUMN code_failures_since TIMESTAMPTZ;
