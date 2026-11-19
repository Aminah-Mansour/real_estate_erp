-- Tests for db/seeds/dev_jeddah_lands.sql. Run by scripts/test_schema.sh in a separate, empty database
-- (seed_test) after: one run WITHOUT the development flag (must do nothing), then two runs WITH it.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
\o /dev/null

SET search_path = public, tests;
CREATE TABLE tests.t_results (n serial PRIMARY KEY, name text NOT NULL, ok boolean NOT NULL, detail text);
CREATE FUNCTION tests.t_true(p_name text, p_expr text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE b boolean;
BEGIN
  EXECUTE 'SELECT (' || p_expr || ')' INTO b;
  INSERT INTO t_results (name, ok, detail) VALUES (p_name, coalesce(b, false), CASE WHEN b THEN 'ok' ELSE 'false: ' || p_expr END);
END $$;

-- Each seeded land, keyed by the exact Unicode code points of its identity:
--   city جدة = U+062C U+062F U+0629; plan 99/أ ends in U+0623 (ALEF WITH HAMZA ABOVE); plan 29/ب ends in U+0628 (BEH)
CREATE TEMP VIEW seeded AS
SELECT * FROM lands WHERE city = U&'\062C\062F\0629';

SELECT t_true('guard: running the seed without -v seed_env=development inserts nothing',
  $$(SELECT lands_after_refused_run FROM tests.seed_guard_check) = 0$$);
SELECT t_true('idempotent: two development runs leave exactly 3 lands (no duplicates)',
  $$(SELECT count(*) FROM lands) = 3 AND (SELECT count(*) FROM seeded) = 3$$);
SELECT t_true('idempotent: the second run changed nothing (same ids, values and created_at)',
  $$NOT EXISTS (
      (SELECT id, city, plan_number, land_number, area_sqm, street_width_m, purchase_price, status, created_at FROM tests.seed_snapshot
       EXCEPT
       SELECT id, city, plan_number, land_number, area_sqm, street_width_m, purchase_price, status, created_at FROM lands)
      UNION ALL
      (SELECT id, city, plan_number, land_number, area_sqm, street_width_m, purchase_price, status, created_at FROM lands
       EXCEPT
       SELECT id, city, plan_number, land_number, area_sqm, street_width_m, purchase_price, status, created_at FROM tests.seed_snapshot))$$);
SELECT t_true('arabic: city stored as جدة exactly (U+062C U+062F U+0629, UTF-8 d8acd8afd8a9)',
  $$(SELECT bool_and(encode(convert_to(city, 'UTF8'), 'hex') = 'd8acd8afd8a9') FROM seeded)$$);
SELECT t_true('arabic: plan 99/أ stored exactly, in logical order (UTF-8 39392fd8a3)',
  $$EXISTS (SELECT 1 FROM seeded WHERE plan_number = U&'99/\0623' AND encode(convert_to(plan_number, 'UTF8'), 'hex') = '39392fd8a3')$$);
SELECT t_true('arabic: plan 29/ب stored exactly, in logical order (UTF-8 32392fd8a8)',
  $$EXISTS (SELECT 1 FROM seeded WHERE plan_number = U&'29/\0628' AND encode(convert_to(plan_number, 'UTF8'), 'hex') = '32392fd8a8')$$);
SELECT t_true('land 1: جدة 99/أ plot 1200, 900 m2, 16 m street, SAR 1,500,000, prospective',
  $$(SELECT (land_number, area_sqm, street_width_m, purchase_price, status, acquired_on IS NULL)
       = ('1200', 900.00, 16.00, 1500000.00, 'prospective', true) FROM seeded WHERE plan_number = U&'99/\0623')$$);
SELECT t_true('land 2: جدة 29/ب plot 400, 900 m2, 16 m street, SAR 1,200,000, prospective',
  $$(SELECT (land_number, area_sqm, street_width_m, purchase_price, status, acquired_on IS NULL)
       = ('400', 900.00, 16.00, 1200000.00, 'prospective', true) FROM seeded WHERE plan_number = U&'29/\0628')$$);
SELECT t_true('land 3: جدة 87 plot 560, 880 m2, 16 m street, SAR 1,700,000, prospective',
  $$(SELECT (land_number, area_sqm, street_width_m, purchase_price, status, acquired_on IS NULL)
       = ('560', 880.00, 16.00, 1700000.00, 'prospective', true) FROM seeded WHERE plan_number = '87')$$);
SELECT t_true('charges 1: 1,500,000 -> tax 75,000 + Dalalah 37,500 = 1,612,500 (preview, not recorded)',
  $$(SELECT (purchase_tax, dalalah, total_acquisition_cost, purchase_recorded) = (75000.00, 37500.00, 1612500.00, false)
       FROM land_acquisition_preview WHERE plan_number = U&'99/\0623' AND land_number = '1200')$$);
SELECT t_true('charges 2: 1,200,000 -> tax 60,000 + Dalalah 30,000 = 1,290,000 (preview, not recorded)',
  $$(SELECT (purchase_tax, dalalah, total_acquisition_cost, purchase_recorded) = (60000.00, 30000.00, 1290000.00, false)
       FROM land_acquisition_preview WHERE plan_number = U&'29/\0628' AND land_number = '400')$$);
SELECT t_true('charges 3: 1,700,000 -> tax 85,000 + Dalalah 42,500 = 1,827,500 (preview, not recorded)',
  $$(SELECT (purchase_tax, dalalah, total_acquisition_cost, purchase_recorded) = (85000.00, 42500.00, 1827500.00, false)
       FROM land_acquisition_preview WHERE plan_number = '87' AND land_number = '560')$$);
SELECT t_true('no fake data: no investors, portfolios, deals, funding, purchases, journal entries or money movements',
  $$(SELECT count(*) FROM investors) + (SELECT count(*) FROM portfolios) + (SELECT count(*) FROM deals)
    + (SELECT count(*) FROM funding_accounts) + (SELECT count(*) FROM land_purchases)
    + (SELECT count(*) FROM journal_entries) + (SELECT count(*) FROM journal_lines)
    + (SELECT count(*) FROM capital_movements) + (SELECT count(*) FROM deal_sales) + (SELECT count(*) FROM payouts) = 0$$);
SELECT t_true('city: all three seeded lands resolve to city code jeddah, English name Jeddah',
  $$(SELECT bool_and(l.city_code = 'jeddah' AND c.name_en = 'Jeddah') FROM seeded l JOIN cities c ON c.code = l.city_code)$$);
CREATE FUNCTION tests.t_dup_rejected(p_city text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  PERFORM erp_act_as_system();
  INSERT INTO lands (city, plan_number, land_number) VALUES (p_city, '87', '560');
  RAISE EXCEPTION 'T_NO_ERROR';
EXCEPTION
  WHEN unique_violation THEN RETURN true;
  WHEN OTHERS THEN RETURN false;
END $$;
SELECT t_true('city: the same seeded land entered as "Jeddah" is recognized as a duplicate',
  $$t_dup_rejected('Jeddah')$$);
SELECT t_true('accountability: seeded lands were created by the system user, never updated',
  $$(SELECT bool_and(created_by = erp_system_user_id() AND updated_by IS NULL AND updated_at IS NULL) FROM seeded)$$);
SELECT t_true('accountability: audit trail holds exactly one "create" per seeded land, by the system user (second run wrote nothing)',
  $$(SELECT count(*) FILTER (WHERE action = 'create' AND entity_type = 'lands' AND actor_id = erp_system_user_id()) = 3
            AND count(*) = 3 FROM audit_events)$$);
SELECT t_true('no fake data: the only employee is the built-in system user (no fake accounts or credentials)',
  $$(SELECT count(*) FROM app_users) = 1 AND (SELECT bool_and(is_system) FROM app_users)
    AND (SELECT count(*) FROM user_credentials) = 0$$);
SELECT t_true('no fake data: no purchase dates, street names or asking prices invented',
  $$(SELECT bool_and(acquired_on IS NULL AND street IS NULL AND sale_price IS NULL AND title IS NULL) FROM seeded)$$);

\o
\pset footer off
SELECT n AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name AS test, left(detail, 100) AS detail
  FROM t_results ORDER BY n;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed, count(*) AS total FROM t_results;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM t_results WHERE NOT ok) THEN RAISE EXCEPTION 'seed tests failed'; END IF; END $$;
