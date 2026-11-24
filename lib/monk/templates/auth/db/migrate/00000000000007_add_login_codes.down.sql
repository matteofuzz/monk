ALTER TABLE login_requests DROP COLUMN code_failures_since;
ALTER TABLE login_requests DROP COLUMN code_failures;
DROP INDEX login_tokens_email_created_at;
ALTER TABLE login_tokens DROP COLUMN code_attempts;
ALTER TABLE login_tokens DROP COLUMN code_hash;
