-- Creates (or updates the passwords of) the per-environment database logins for the application and
-- the login service. Run as the schema owner with psql:
--   psql ... -v ON_ERROR_STOP=1 -v app_pw=... -v auth_pw=... -f db/dev_logins.sql
-- The passwords come from the environment (.env); they are never written to the repository.

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_app_login') AS create_app_login \gset
\if :create_app_login
  CREATE ROLE erp_app_login LOGIN PASSWORD :'app_pw' IN ROLE erp_app;
\else
  ALTER ROLE erp_app_login PASSWORD :'app_pw';
\endif

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_auth_login') AS create_auth_login \gset
\if :create_auth_login
  CREATE ROLE erp_auth_login LOGIN PASSWORD :'auth_pw' IN ROLE erp_auth;
\else
  ALTER ROLE erp_auth_login PASSWORD :'auth_pw';
\endif
