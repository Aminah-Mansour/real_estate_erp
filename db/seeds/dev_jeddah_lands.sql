-- DEVELOPMENT SEED DATA ONLY. Never run against a production database.
--
-- Three Jeddah lands, seeded as prospective (not yet bought). Only facts that were provided are stored:
-- city, plan number, plot (land) number, area, street width and purchase price. No investors, deals,
-- purchase dates, bank transactions or accounting entries are created. Purchase tax (5%) and Dalalah
-- (2.5%) are not stored for prospective lands; they are shown by the land_acquisition_preview view, which
-- uses the same rule functions as recorded purchases.
--
-- Idempotent: safe to run any number of times. A land is identified by city + plan number + land number;
-- re-running refreshes the seeded facts while the land is still prospective and never touches a land that
-- has moved on (for example, been bought).
--
-- Usage (refuses to run without the development flag):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v seed_env=development -f db/seeds/dev_jeddah_lands.sql

\if :{?seed_env}
\else
  \echo 'Refusing to seed: this is development data. Re-run with -v seed_env=development'
  \quit
\endif
SELECT :'seed_env' = 'development' AS seed_env_ok \gset
\if :seed_env_ok
\else
  \echo 'Refusing to seed: seed_env must be exactly "development"'
  \quit
\endif

SET client_encoding = 'UTF8';

BEGIN;

INSERT INTO lands (city, plan_number, land_number, area_sqm, street_width_m, purchase_price, status)
VALUES
  ('جدة', '99/أ', '1200', 900, 16, 1500000, 'prospective'),
  ('جدة', '29/ب', '400',  900, 16, 1200000, 'prospective'),
  ('جدة', '87',   '560',  880, 16, 1700000, 'prospective')
ON CONFLICT ON CONSTRAINT lands_identity_uq DO UPDATE
   SET area_sqm = EXCLUDED.area_sqm,
       street_width_m = EXCLUDED.street_width_m,
       purchase_price = EXCLUDED.purchase_price
 WHERE lands.status = 'prospective';

COMMIT;

\echo 'Seeded Jeddah development lands (purchase charges are a preview; nothing has been bought):'
SELECT city, plan_number, land_number, purchase_price, purchase_tax, dalalah, total_acquisition_cost, purchase_recorded
  FROM land_acquisition_preview
 WHERE city = 'جدة' AND (plan_number, land_number) IN (('99/أ', '1200'), ('29/ب', '400'), ('87', '560'))
 ORDER BY plan_number, land_number;
