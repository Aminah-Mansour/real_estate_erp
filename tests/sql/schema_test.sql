-- Tests for real_estate_erp_schema.sql. Run with scripts/test_schema.sh (throwaway PostgreSQL container).
-- Each test runs in a subtransaction: t_ok keeps its changes, t_err expects an error containing a pattern
-- and rolls back. Deferred (commit-time) checks are forced with SET CONSTRAINTS ALL IMMEDIATE.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
\o /dev/null

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
CREATE TABLE t_results (n serial PRIMARY KEY, name text NOT NULL, ok boolean NOT NULL, detail text);

CREATE FUNCTION u(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT lpad(to_hex(n), 32, '0')::uuid $$;

CREATE FUNCTION t_ok(p_name text, VARIADIC p_stmts text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s text;
BEGIN
  BEGIN
    FOREACH s IN ARRAY p_stmts LOOP EXECUTE s; END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    INSERT INTO t_results (name, ok, detail) VALUES (p_name, true, 'ok');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t_results (name, ok, detail) VALUES (p_name, false, 'unexpected error: ' || SQLERRM);
  END;
END $$;

CREATE FUNCTION t_err(p_name text, p_pattern text, VARIADIC p_stmts text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s text;
BEGIN
  BEGIN
    FOREACH s IN ARRAY p_stmts LOOP EXECUTE s; END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'T_NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'T_NO_ERROR' THEN
      INSERT INTO t_results (name, ok, detail) VALUES (p_name, false, 'expected an error, none raised');
    ELSIF position(lower(p_pattern) IN lower(SQLERRM)) > 0 THEN
      INSERT INTO t_results (name, ok, detail) VALUES (p_name, true, 'rejected: ' || SQLERRM);
    ELSE
      INSERT INTO t_results (name, ok, detail) VALUES (p_name, false, 'wrong error: ' || SQLERRM);
    END IF;
  END;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

CREATE FUNCTION t_true(p_name text, p_expr text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE b boolean;
BEGIN
  EXECUTE 'SELECT (' || p_expr || ')' INTO b;
  INSERT INTO t_results (name, ok, detail) VALUES (p_name, coalesce(b, false), CASE WHEN b THEN 'ok' ELSE 'false: ' || p_expr END);
END $$;

-- Ledger accounts used below: u(21) bank (cash), u(22) land inventory, u(23) investor capital,
-- u(24) land sale revenue, u(25) distributions payable, u(26) deal expenses, u(27) D1 project costs (D1 only).

-- Draft entry with one debit and one credit line; posted unless p_post is false.
CREATE FUNCTION t_entry(p_id uuid, p_debit uuid, p_credit uuid, p_amount numeric,
                        p_post boolean DEFAULT true, p_reverses uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO journal_entries (id, occurred_on, description, reverses_entry_id) VALUES (p_id, current_date, 'test entry', p_reverses);
  INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit) VALUES (p_id, p_debit, p_amount);
  INSERT INTO journal_lines (journal_entry_id, ledger_account_id, credit) VALUES (p_id, p_credit, p_amount);
  IF p_post THEN
    UPDATE journal_entries SET status = 'posted', posted_at = now(), approved_by = u(9999) WHERE id = p_id;
  END IF;
  RETURN p_id;
END $$;

-- Exact reversal of p_orig, posted, with p_orig marked reversed.
CREATE FUNCTION t_reverse(p_new uuid, p_orig uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO journal_entries (id, occurred_on, description, reverses_entry_id) VALUES (p_new, current_date, 'reversal', p_orig);
  INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit, credit, portfolio_id, deal_id, investor_id)
    SELECT p_new, ledger_account_id, credit, debit, portfolio_id, deal_id, investor_id
      FROM journal_lines WHERE journal_entry_id = p_orig;
  UPDATE journal_entries SET status = 'posted', posted_at = now(), approved_by = u(9999) WHERE id = p_new;
  UPDATE journal_entries SET status = 'reversed' WHERE id = p_orig;
END $$;

-- Capital movement backed by a posted entry.
CREATE FUNCTION t_move(p_id uuid, p_account uuid, p_kind text, p_amount numeric, p_group uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE je uuid := gen_random_uuid();
BEGIN
  IF p_kind IN ('contribution','transfer_in') THEN
    PERFORM t_entry(je, u(21), u(23), p_amount);
  ELSE
    PERFORM t_entry(je, u(23), u(21), p_amount);
  END IF;
  INSERT INTO capital_movements (id, funding_account_id, kind, amount, effective_on, transfer_group_id, journal_entry_id)
  VALUES (coalesce(p_id, gen_random_uuid()), p_account, p_kind, p_amount, current_date, p_group, je);
END $$;

-- Land purchase: pays price + 5% purchase tax + 2.5% Dalalah from the bank.
CREATE FUNCTION t_purchase(p_deal uuid, p_land uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE je uuid := gen_random_uuid(); price numeric;
BEGIN
  SELECT purchase_price INTO price FROM lands WHERE id = p_land;
  PERFORM t_entry(je, u(22), u(21), price + round(price * 0.05, 2) + round(price * 0.025, 2));
  INSERT INTO land_purchases (deal_id, land_id, amount, paid_on, journal_entry_id) VALUES (p_deal, p_land, price, current_date, je);
END $$;

-- Expense paid from the bank, against p_land (NULL = the deal's original land).
CREATE FUNCTION t_cost(p_id uuid, p_deal uuid, p_amount numeric, p_account uuid DEFAULT u(26), p_category text DEFAULT 'survey',
                       p_land uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE je uuid := gen_random_uuid();
BEGIN
  INSERT INTO journal_entries (id, occurred_on, description) VALUES (je, current_date, 'deal cost');
  INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit, deal_id) VALUES (je, p_account, p_amount, p_deal);
  INSERT INTO journal_lines (journal_entry_id, ledger_account_id, credit) VALUES (je, u(21), p_amount);
  UPDATE journal_entries SET status = 'posted', posted_at = now(), approved_by = u(9999) WHERE id = je;
  INSERT INTO deal_costs (id, deal_id, land_id, category, amount, incurred_on, journal_entry_id)
  VALUES (coalesce(p_id, gen_random_uuid()), p_deal, p_land, p_category, p_amount, current_date, je);
END $$;

-- A sale paid in full: posted entry debiting cash by the sale amount, then the sale row.
CREATE FUNCTION t_sale(p_sale uuid, p_deal uuid, p_land uuid, p_amount numeric, p_entry uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t_entry(p_entry, u(21), u(24), p_amount);
  INSERT INTO deal_sales (id, deal_id, land_id, sale_amount, sold_on, buyer_name, payment_reference, journal_entry_id)
  VALUES (p_sale, p_deal, p_land, p_amount, current_date, 'Buyer ' || p_sale, 'TRX-' || p_sale, p_entry);
END $$;

CREATE FUNCTION t_parcel(p_id uuid, p_parent uuid, p_land_number text, p_price numeric DEFAULT NULL, p_area numeric DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO lands (id, parent_land_id, city, plan_number, land_number, status, purchase_price, area_sqm)
  SELECT p_id, p_parent, city, plan_number, p_land_number, 'available', p_price, p_area FROM lands WHERE id = p_parent;
END $$;

-- Draft profit realization for one sale (expenses are allocated automatically on approval).
CREATE FUNCTION t_realize(p_id uuid, p_deal uuid, p_sale uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO profit_realizations (id, deal_id, deal_sale_id, realized_on) VALUES (p_id, p_deal, p_sale, current_date);
END $$;

-- Draft closing realization for a deal's leftover expenses.
CREATE FUNCTION t_close(p_id uuid, p_deal uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO profit_realizations (id, deal_id, kind, realized_on) VALUES (p_id, p_deal, 'closing', current_date);
END $$;

CREATE FUNCTION t_approve_realization(p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE profit_realizations SET status = 'approved', approved_by = u(9999) WHERE id = p_id;
END $$;

CREATE FUNCTION t_line(p_id uuid, p_batch uuid, p_account uuid, p_type text, p_capital numeric, p_profit numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO distribution_lines (id, batch_id, funding_account_id, beneficiary_type, amount, capital_component, profit_component)
  VALUES (coalesce(p_id, gen_random_uuid()), p_batch, p_account, p_type, p_capital + p_profit, p_capital, p_profit);
END $$;

CREATE FUNCTION t_office(p_id uuid, p_batch uuid, p_amount numeric) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO distribution_lines (id, batch_id, beneficiary_type, amount) VALUES (coalesce(p_id, gen_random_uuid()), p_batch, 'office', p_amount);
END $$;

CREATE FUNCTION t_approve_batch(p_batch uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE je uuid := gen_random_uuid(); amt numeric;
BEGIN
  SELECT amount INTO amt FROM distribution_batches WHERE id = p_batch;
  PERFORM t_entry(je, u(24), u(25), amt);
  UPDATE distribution_batches SET status = 'approved', approved_at = now(), journal_entry_id = je WHERE id = p_batch;
END $$;

CREATE FUNCTION t_payout(p_line uuid, p_amount numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE je uuid := gen_random_uuid();
BEGIN
  PERFORM t_entry(je, u(25), u(21), p_amount);
  INSERT INTO payouts (distribution_line_id, amount, paid_on, journal_entry_id) VALUES (p_line, p_amount, current_date, je);
END $$;

CREATE FUNCTION land_status(p_id uuid) RETURNS text LANGUAGE sql AS $$ SELECT status FROM lands WHERE id = p_id $$;

-- ---------------------------------------------------------------------------
-- Fixtures (acquisition cost = price x 1.075)
--   investors I1 u(1), I2 u(2), I3 u(3); portfolios P1 u(11) (shared by I1 + I2), P2 u(12)
--   L1 u(101) Riyadh 1,000,000, 3000 m2 -> D1 u(201): acquisition 1,075,000 funded by P1 645,000 (u(303)) + I3 430,000 (u(304))
--   L2 u(102) Jeddah 1,000,000          -> D2 u(202): acquisition 1,075,000 funded by I1 (u(305))  [the worked example]
--   L4 u(106) Taif     500,000          -> D4 u(204): acquisition   537,500 funded by I2 (u(306))
--   L5 u(109) Medina   400,000          -> D5 u(207): acquisition   430,000 funded by I3 440,000 (u(311))
--   P1 cash after funding D1: 1,000,000 - 645,000 = 355,000
-- ---------------------------------------------------------------------------
INSERT INTO investors (id, full_name) VALUES (u(1), 'Investor One'), (u(2), 'Investor Two'), (u(3), 'Investor Three');
INSERT INTO portfolios (id, name) VALUES (u(11), 'Shared Portfolio One'), (u(12), 'Portfolio Two');

INSERT INTO ledger_accounts (id, code, name, account_type, is_cash) VALUES
  (u(21), '1000', 'Bank', 'asset', true),
  (u(22), '1200', 'Land inventory', 'asset', false),
  (u(23), '3000', 'Investor capital', 'equity', false),
  (u(24), '4000', 'Land sale revenue', 'revenue', false),
  (u(25), '2100', 'Distributions payable', 'liability', false),
  (u(26), '5000', 'Deal expenses', 'expense', false);

INSERT INTO lands (id, city, plan_number, land_number, street, purchase_price, sale_price, area_sqm, status, acquired_on) VALUES
  (u(101), 'Riyadh', '1234', '10', 'Al Olaya St', 1000000, 1500000, 3000, 'available', '2026-01-15'),
  (u(102), 'Jeddah', '555', '7', 'Tahlia St', 1000000, 1500000, NULL, 'available', '2026-02-01'),
  (u(106), 'Taif', '31', '2', NULL, 500000, NULL, NULL, 'available', '2026-02-10'),
  (u(109), 'Medina', '88', '5', NULL, 400000, NULL, 2000, 'available', '2026-02-20');

INSERT INTO deals (id, land_id, name, status) VALUES
  (u(201), u(101), 'Riyadh 1234/10', 'active'),
  (u(202), u(102), 'Jeddah 555/7', 'active'),
  (u(204), u(106), 'Taif 31/2', 'active'),
  (u(207), u(109), 'Medina 88/5', 'active');

INSERT INTO ledger_accounts (id, code, name, account_type, deal_id) VALUES (u(27), '1300', 'D1 project costs', 'asset', u(201));

INSERT INTO funding_accounts (id, portfolio_id, deal_id, investor_id, parent_portfolio_id) VALUES
  (u(301), u(11), NULL, u(1), NULL),     -- I1 in P1
  (u(302), u(11), NULL, u(2), NULL),     -- I2 in P1
  (u(303), NULL, u(201), NULL, u(11)),   -- P1 in D1
  (u(304), NULL, u(201), u(3), NULL),    -- I3 directly in D1
  (u(305), NULL, u(202), u(1), NULL),    -- I1 directly in D2
  (u(306), NULL, u(204), u(2), NULL),    -- I2 directly in D4
  (u(307), u(12), NULL, u(3), NULL),     -- I3 in P2
  (u(311), NULL, u(207), u(3), NULL);    -- I3 directly in D5

SELECT t_move(u(801), u(301), 'contribution', 600000);
SELECT t_move(u(802), u(302), 'contribution', 400000);
SELECT t_move(u(803), u(303), 'contribution', 645000);
SELECT t_move(u(804), u(304), 'contribution', 430000);
SELECT t_move(u(805), u(305), 'contribution', 1075000);
SELECT t_move(u(806), u(306), 'contribution', 537500);
SELECT t_move(u(807), u(311), 'contribution', 440000);
SELECT t_purchase(u(201), u(101));
SELECT t_purchase(u(202), u(102));
SELECT t_purchase(u(204), u(106));
SELECT t_purchase(u(207), u(109));

-- ---------------------------------------------------------------------------
-- Purchase charges: 5% purchase tax + 2.5% Dalalah, on purchase only
-- ---------------------------------------------------------------------------
SELECT t_true('purchase: 1,000,000 land -> purchase tax 50,000 + Dalalah 25,000 = acquisition cost 1,075,000',
  $$(SELECT (amount, purchase_tax, dalalah, total_cost) = (1000000.00, 50000.00, 25000.00, 1075000.00)
       FROM land_purchases WHERE deal_id = u(202))$$);
SELECT t_true('purchase: deal cash is reduced by the full acquisition cost', $$deal_cash(u(202)) = 0$$);
SELECT t_true('naming: dalalah column documents its English and Arabic UI labels',
  $$col_description('land_purchases'::regclass,
      (SELECT attnum FROM pg_attribute WHERE attrelid = 'land_purchases'::regclass AND attname = 'dalalah'))
    LIKE 'Land Purchase Brokerage Commission (Dalalah) / دلالة شراء الأرض: 2.5% of the purchase price%'$$);
SELECT t_err('purchase: tax and Dalalah cannot be entered by hand', 'cannot insert a non-default value',
  $$INSERT INTO land_purchases (deal_id, land_id, amount, purchase_tax, paid_on, journal_entry_id)
    VALUES (u(201), u(101), 1000000, 0, current_date, gen_random_uuid())$$);
SELECT t_err('purchase: a deal pays for its land (and its charges) only once', 'duplicate key value violates unique constraint "land_purchases_',
  $$SELECT t_purchase(u(201), u(101))$$);
SELECT t_err('purchase: amount must equal the land''s purchase_price', 'must equal the land''s purchase_price',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(107), 'Abha', '12', '4', 100000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name, status) VALUES (u(205), u(107), 'Abha 12/4', 'active')$$,
  $$SELECT t_entry(u(1170), u(22), u(21), 96750)$$,
  $$INSERT INTO land_purchases (deal_id, land_id, amount, paid_on, journal_entry_id) VALUES (u(205), u(107), 90000, current_date, u(1170))$$);
SELECT t_err('purchase: cash paid must include purchase tax and Dalalah', 'cash paid 100000.00 must equal',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(107), 'Abha', '12', '4', 100000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name, status) VALUES (u(205), u(107), 'Abha 12/4', 'active')$$,
  $$INSERT INTO funding_accounts (id, deal_id, investor_id) VALUES (u(309), u(205), u(3))$$,
  $$SELECT t_move(NULL, u(309), 'contribution', 107500)$$,
  $$SELECT t_entry(u(1171), u(22), u(21), 100000)$$,
  $$INSERT INTO land_purchases (deal_id, land_id, amount, paid_on, journal_entry_id) VALUES (u(205), u(107), 100000, current_date, u(1171))$$);
SELECT t_err('purchase: cannot exceed deal cash (acquisition 107,500, cash 100,000)', 'deal cash would be',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(107), 'Abha', '12', '4', 100000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name, status) VALUES (u(205), u(107), 'Abha 12/4', 'active')$$,
  $$INSERT INTO funding_accounts (id, deal_id, investor_id) VALUES (u(309), u(205), u(3))$$,
  $$SELECT t_move(NULL, u(309), 'contribution', 100000)$$,
  $$SELECT t_purchase(u(205), u(107))$$);
SELECT t_err('purchase: recorded purchase cannot be changed', 'cannot be changed or deleted',
  $$UPDATE land_purchases SET paid_on = current_date - 1 WHERE deal_id = u(201)$$);
SELECT t_err('purchase: Dalalah cannot be charged again as a deal expense', 'deal_costs_not_computed_charge',
  $$SELECT t_cost(NULL, u(201), 25000, u(26), 'dalalah')$$);
SELECT t_err('purchase: purchase tax cannot be charged again as a deal expense', 'deal_costs_not_computed_charge',
  $$SELECT t_cost(NULL, u(201), 50000, u(26), ' Purchase_Tax ')$$);
SELECT t_err('office fee: cannot be recorded as a deal expense', 'deal_costs_not_computed_charge',
  $$SELECT t_cost(NULL, u(201), 1000, u(26), 'office_fee')$$);
SELECT t_err('tax: VAT cannot be recorded on anything (purchase tax is the only tax)', 'deal_costs_not_computed_charge',
  $$SELECT t_cost(NULL, u(201), 15000, u(26), 'VAT')$$);
SELECT t_true('tax: purchase tax is the only tax column; Dalalah is a separate commission; no VAT column exists',
  $$(SELECT array_agg(table_name || '.' || column_name ORDER BY table_name, column_name) FROM information_schema.columns
      WHERE table_schema = 'public' AND (column_name LIKE '%tax%' OR column_name LIKE '%vat%' OR column_name LIKE '%dalalah%'))
    = ARRAY['land_purchases.dalalah', 'land_purchases.purchase_tax']$$);

-- ---------------------------------------------------------------------------
-- Lands
-- ---------------------------------------------------------------------------
SELECT t_ok('land: create with city, plan_number, land_number, street, purchase_price, sale_price',
  $$INSERT INTO lands (id, city, plan_number, land_number, street, purchase_price, sale_price, status, acquired_on)
    VALUES (u(103), 'Dammam', '900', '1', 'King Fahd Rd', 500000, 650000, 'available', '2026-03-01')$$);
SELECT t_err('land: duplicate city + plan_number + land_number rejected', 'lands_identity_uq',
  $$INSERT INTO lands (city, plan_number, land_number) VALUES ('Riyadh', '1234', '10')$$);
SELECT t_ok('land: same plan_number + land_number allowed in another city',
  $$INSERT INTO lands (city, plan_number, land_number) VALUES ('Jeddah', '1234', '10')$$);
SELECT t_err('land: city is required', 'column "city"',
  $$INSERT INTO lands (plan_number, land_number) VALUES ('1', '1')$$);
SELECT t_ok('land: prospective land needs no purchase price',
  $$INSERT INTO lands (id, city, plan_number, land_number) VALUES (u(104), 'Riyadh', '7777', '1')$$);
SELECT t_err('land: acquired (available) land needs purchase_price and acquired_on', 'lands_purchase_recorded',
  $$INSERT INTO lands (city, plan_number, land_number, status) VALUES ('Riyadh', '8888', '1', 'available')$$);
SELECT t_err('land: asking price must be positive', 'lands_sale_price_check',
  $$UPDATE lands SET sale_price = 0 WHERE id = u(103)$$);
SELECT t_ok('land: listed and under_contract can be set manually',
  $$UPDATE lands SET status = 'listed' WHERE id = u(103)$$,
  $$UPDATE lands SET status = 'under_contract' WHERE id = u(103)$$);
SELECT t_err('land: status sold cannot be set manually', 'set automatically',
  $$UPDATE lands SET status = 'sold' WHERE id = u(103)$$);
SELECT t_err('land: status partially_sold cannot be set manually', 'set automatically',
  $$INSERT INTO lands (city, plan_number, land_number, status, purchase_price, acquired_on)
    VALUES ('Riyadh', '9999', '1', 'partially_sold', 1, current_date)$$);
SELECT t_ok('land: prospective -> cancelled allowed',
  $$UPDATE lands SET status = 'cancelled' WHERE id = u(104)$$);
SELECT t_err('land: cannot subdivide a cancelled land', 'cannot subdivide a land with status cancelled',
  $$SELECT t_parcel(u(190), u(104), '1-A')$$);
SELECT t_err('land: parcel must be in the same city as its parent', 'lands_parent_fk',
  $$INSERT INTO lands (parent_land_id, city, plan_number, land_number, status)
    VALUES (u(101), 'Jeddah', '1234', '10-X', 'available')$$);
SELECT t_err('land: parcel cannot be prospective', 'lands_parcel_status',
  $$INSERT INTO lands (parent_land_id, city, plan_number, land_number, status)
    VALUES (u(101), 'Riyadh', '1234', '10-X', 'prospective')$$);

-- ---------------------------------------------------------------------------
-- Deals
-- ---------------------------------------------------------------------------
SELECT t_err('deal: only one open deal per land', 'deals_one_open_per_land',
  $$INSERT INTO deals (land_id, name) VALUES (u(101), 'second deal')$$);
SELECT t_ok('deal: a cancelled deal on the same land is allowed',
  $$INSERT INTO deals (land_id, name, status) VALUES (u(101), 'abandoned deal', 'cancelled')$$);
SELECT t_err('deal: cannot change the land of a deal', 'land_id cannot be changed',
  $$UPDATE deals SET land_id = u(103) WHERE id = u(201)$$);

-- ---------------------------------------------------------------------------
-- Selling an entire land (L2 / D2): the worked example, sold for 1,500,000
-- ---------------------------------------------------------------------------
SELECT t_err('sale: requires a journal entry', 'deal_sales_completed_has_entry',
  $$INSERT INTO deal_sales (deal_id, land_id, sale_amount, sold_on, buyer_name, payment_reference)
    VALUES (u(202), u(102), 1500000, current_date, 'Buyer', 'TRX')$$);
SELECT t_err('sale: journal entry must be posted (payment received)', 'must be posted',
  $$SELECT t_entry(u(1101), u(21), u(24), 1500000, false)$$,
  $$INSERT INTO deal_sales (deal_id, land_id, sale_amount, sold_on, buyer_name, payment_reference, journal_entry_id)
    VALUES (u(202), u(102), 1500000, current_date, 'Buyer', 'TRX', u(1101))$$);
SELECT t_err('sale: partial payment (instalment) rejected', 'no instalments',
  $$SELECT t_entry(u(1102), u(21), u(24), 300000)$$,
  $$INSERT INTO deal_sales (deal_id, land_id, sale_amount, sold_on, buyer_name, payment_reference, journal_entry_id)
    VALUES (u(202), u(102), 1500000, current_date, 'Buyer', 'TRX', u(1102))$$);
SELECT t_err('sale: amount not received into a cash account rejected', 'no instalments',
  $$SELECT t_entry(u(1103), u(22), u(24), 1500000)$$,
  $$INSERT INTO deal_sales (deal_id, land_id, sale_amount, sold_on, buyer_name, payment_reference, journal_entry_id)
    VALUES (u(202), u(102), 1500000, current_date, 'Buyer', 'TRX', u(1103))$$);
SELECT t_ok('sale: entire land sold for 1,500,000, paid in full',
  $$SELECT t_sale(u(406), u(202), u(102), 1500000, u(1104))$$);
SELECT t_true('sale: entire land is now sold', $$land_status(u(102)) = 'sold'$$);
SELECT t_true('sale: no purchase charges on the sale - deal cash rises by exactly 1,500,000', $$deal_cash(u(202)) = 1500000$$);
SELECT t_err('sale: same land cannot be sold twice', 'deal_sales_one_per_land',
  $$SELECT t_sale(u(407), u(202), u(102), 1500000, u(1105))$$);
SELECT t_err('sale: sold land cannot be subdivided', 'cannot subdivide a land with status sold',
  $$SELECT t_parcel(u(191), u(102), '7-A')$$);
SELECT t_err('sale: recorded sale cannot be edited', 'cannot be edited',
  $$UPDATE deal_sales SET sale_amount = 900000 WHERE id = u(406)$$);
SELECT t_err('sale: not allowed while the deal is draft', 'while the deal is draft',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(105), 'Mecca', '42', '3', 100000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name) VALUES (u(203), u(105), 'draft deal')$$,
  $$SELECT t_sale(u(408), u(203), u(105), 120000, u(1106))$$);

-- ---------------------------------------------------------------------------
-- Subdividing and selling parcels separately (L1 / D1)
--   allocated purchase price (acquisition cost = x 1.075):
--   L1 1,000,000 (1,075,000) -> A u(111) 300,000 (322,500), B u(112) 400,000 (430,000), C u(113) 300,000 (322,500)
--   B -> B1 u(121) 200,000 (215,000), B2 u(122) 200,000 (215,000)
-- ---------------------------------------------------------------------------
SELECT t_ok('subdivide: L1 split into parcels A, B, C with allocated purchase price and area',
  $$SELECT t_parcel(u(111), u(101), '10-A', 300000, 900)$$,
  $$SELECT t_parcel(u(112), u(101), '10-B', 400000, 1200)$$,
  $$SELECT t_parcel(u(113), u(101), '10-C', 300000, 900)$$);
SELECT t_true('subdivide: L1 still available before any sale', $$land_status(u(101)) = 'available'$$);
SELECT t_err('subdivide: parcel prices cannot exceed the land''s purchase price', 'parcel costs total',
  $$SELECT t_parcel(u(193), u(101), '10-D', 1)$$);
SELECT t_err('subdivide: parcel areas cannot exceed the land''s area', 'parcel areas total',
  $$SELECT t_parcel(u(194), u(101), '10-E', NULL, 1)$$);
SELECT t_err('subdivide: deal cannot be opened on a parcel', 'original land',
  $$INSERT INTO deals (land_id, name) VALUES (u(111), 'parcel deal')$$);
SELECT t_err('subdivide: a parcel cannot be moved to another parent', 'cannot be changed after creation',
  $$UPDATE lands SET parent_land_id = u(112) WHERE id = u(111)$$);
SELECT t_err('subdivide: subdivided land cannot be sold whole', 'has been subdivided',
  $$SELECT t_sale(u(409), u(201), u(101), 1500000, u(1107))$$);
SELECT t_ok('parcel sale: parcel A sold for 400,000',
  $$SELECT t_sale(u(401), u(201), u(111), 400000, u(1108))$$);
SELECT t_true('parcel sale: A sold, L1 partially_sold',
  $$land_status(u(111)) = 'sold' AND land_status(u(101)) = 'partially_sold'$$);
SELECT t_err('parcel sale: parcel A cannot be sold twice', 'deal_sales_one_per_land',
  $$SELECT t_sale(u(410), u(201), u(111), 400000, u(1109))$$);
SELECT t_err('parcel sale: parcel must belong to the deal''s land', 'is not the land of deal',
  $$SELECT t_sale(u(411), u(202), u(112), 400000, u(1110))$$);
SELECT t_err('parcel sale: a sold parcel cannot be subdivided', 'cannot subdivide',
  $$SELECT t_parcel(u(192), u(111), '10-A-1')$$);
SELECT t_ok('parcel sale: B subdivided again into B1, B2; B1 sold for 250,000',
  $$SELECT t_parcel(u(121), u(112), '10-B-1', 200000, 600)$$,
  $$SELECT t_parcel(u(122), u(112), '10-B-2', 200000, 600)$$,
  $$SELECT t_sale(u(402), u(201), u(121), 250000, u(1111))$$);
SELECT t_true('parcel sale: B partially_sold, L1 partially_sold',
  $$land_status(u(112)) = 'partially_sold' AND land_status(u(101)) = 'partially_sold'$$);
SELECT t_err('parcel sale: B cannot be sold whole after subdividing', 'has been subdivided',
  $$SELECT t_sale(u(412), u(201), u(112), 500000, u(1112))$$);
SELECT t_ok('parcel sale: B2 sold for 260,000 and C for 700,000',
  $$SELECT t_sale(u(403), u(201), u(122), 260000, u(1113))$$,
  $$SELECT t_sale(u(404), u(201), u(113), 700000, u(1114))$$);
SELECT t_true('parcel sale: all parcels sold -> B sold, L1 sold',
  $$land_status(u(112)) = 'sold' AND land_status(u(101)) = 'sold'$$);
SELECT t_err('parcel sale: status of a sold land cannot be changed manually', 'set automatically',
  $$UPDATE lands SET status = 'listed' WHERE id = u(101)$$);

-- Correcting a sale: reverse its journal entry and void it, then sell again.
SELECT t_err('void: sale cannot be voided before its journal entry is reversed', 'reverse its journal entry',
  $$UPDATE deal_sales SET status = 'voided' WHERE id = u(404)$$);
SELECT t_err('void: journal entry of a sale cannot be reversed without voiding the sale', 'void the deal sale',
  $$SELECT t_reverse(u(1115), u(1114))$$);
SELECT t_ok('void: reverse journal entry and void sale of C',
  $$SELECT t_reverse(u(1115), u(1114))$$,
  $$UPDATE deal_sales SET status = 'voided' WHERE id = u(404)$$);
SELECT t_true('void: C available again, L1 back to partially_sold',
  $$land_status(u(113)) = 'available' AND land_status(u(101)) = 'partially_sold'$$);
SELECT t_err('void: voided sale cannot be restored', 'cannot be restored',
  $$UPDATE deal_sales SET status = 'completed' WHERE id = u(404)$$);
SELECT t_ok('void: C sold again to a new buyer for 720,000',
  $$SELECT t_sale(u(405), u(201), u(113), 720000, u(1116))$$);
SELECT t_true('void: L1 sold again', $$land_status(u(101)) = 'sold'$$);

-- ---------------------------------------------------------------------------
-- Investor contributions, withdrawals, transfers, shared portfolios
--   after this section: P1 cash 405,000; I1 in P1 committed 950,000; I2 in P1 700,000;
--   P1 in D1 1,245,000 and I3 in D1 830,000 (60% / 40%)
-- ---------------------------------------------------------------------------
SELECT t_ok('capital: I1 contributes 500,000 to shared portfolio P1', $$SELECT t_move(u(811), u(301), 'contribution', 500000)$$);
SELECT t_ok('capital: I2 contributes 300,000 to the same portfolio P1', $$SELECT t_move(u(812), u(302), 'contribution', 300000)$$);
SELECT t_ok('capital: P1 invests 600,000 more in deal D1', $$SELECT t_move(u(813), u(303), 'contribution', 600000)$$);
SELECT t_ok('capital: I3 invests 400,000 more directly in deal D1', $$SELECT t_move(u(814), u(304), 'contribution', 400000)$$);
SELECT t_ok('capital: I1 withdraws 50,000 of uninvested cash from P1', $$SELECT t_move(u(815), u(301), 'withdrawal', 50000)$$);
SELECT t_err('capital: amount must be positive', 'capital_movements_amount_check',
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, journal_entry_id)
    VALUES (u(301), 'contribution', 0, current_date, gen_random_uuid())$$);
SELECT t_err('capital: transfer requires a transfer group', 'capital_movements_transfer_group',
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, journal_entry_id)
    VALUES (u(301), 'transfer_out', 100, current_date, gen_random_uuid())$$);
SELECT t_err('capital: one-sided transfer rejected', 'exactly one transfer_out and one transfer_in',
  $$SELECT t_move(NULL, u(301), 'transfer_out', 100000, u(601))$$);
SELECT t_err('capital: transfer legs with different amounts rejected', 'exactly one transfer_out and one transfer_in',
  $$SELECT t_move(NULL, u(301), 'transfer_out', 100000, u(601))$$,
  $$SELECT t_move(NULL, u(305), 'transfer_in', 90000, u(601))$$);
SELECT t_ok('capital: I1 transfers 100,000 from P1 into direct deal D2',
  $$SELECT t_move(u(816), u(301), 'transfer_out', 100000, u(601))$$,
  $$SELECT t_move(u(817), u(305), 'transfer_in', 100000, u(601))$$);
SELECT t_true('capital: P1 cash is 405,000', $$portfolio_cash(u(11)) = 405000$$);
SELECT t_err('capital: movement requires a journal entry', 'journal_entry_id',
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on) VALUES (u(302), 'contribution', 1000, current_date)$$);
SELECT t_err('capital: movement journal entry must be posted', 'journal entry must be posted',
  $$SELECT t_entry(u(1152), u(21), u(23), 1000, false)$$,
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, journal_entry_id)
    VALUES (u(302), 'contribution', 1000, current_date, u(1152))$$);
SELECT t_err('capital: one journal entry cannot back two movements', 'capital_movements_journal_entry_id_key',
  $$SELECT t_entry(u(1151), u(21), u(23), 1000)$$,
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, journal_entry_id) VALUES
    (u(302), 'contribution', 1000, current_date, u(1151)),
    (u(304), 'contribution', 1000, current_date, u(1151))$$);
SELECT t_err('capital: recorded movement cannot be edited', 'cannot be changed or deleted',
  $$UPDATE capital_movements SET amount = 1 WHERE id = u(811)$$);
SELECT t_err('capital: recorded movement cannot be deleted', 'cannot be changed or deleted',
  $$DELETE FROM capital_movements WHERE id = u(811)$$);
SELECT t_err('capital: journal entry of a movement cannot be reversed', 'compensating',
  $$SELECT t_reverse(gen_random_uuid(), (SELECT journal_entry_id FROM capital_movements WHERE id = u(811)))$$);
SELECT t_err('journal amount: 1,000,000 contribution backed by a 1 SAR entry rejected', 'moves 1.00 in cash but the contribution is 1000000.00',
  $$SELECT t_entry(u(1153), u(21), u(23), 1)$$,
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, journal_entry_id)
    VALUES (u(302), 'contribution', 1000000, current_date, u(1153))$$);
SELECT t_err('journal amount: a withdrawal must pay cash out, not in', 'moves 1000.00 in cash but the withdrawal is 1000.00',
  $$SELECT t_entry(u(1154), u(21), u(23), 1000)$$,
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, journal_entry_id)
    VALUES (u(302), 'withdrawal', 1000, current_date, u(1154))$$);
SELECT t_err('journal amount: each transfer leg''s entry must match its amount', 'totals 1.00 but the transfer is 5000.00',
  $$SELECT t_entry(u(1155), u(21), u(23), 1)$$,
  $$INSERT INTO capital_movements (funding_account_id, kind, amount, effective_on, transfer_group_id, journal_entry_id)
    VALUES (u(302), 'transfer_out', 5000, current_date, u(602), u(1155))$$,
  $$SELECT t_move(NULL, u(304), 'transfer_in', 5000, u(602))$$);
SELECT t_ok('timing: a movement''s recorded time is set by the database (backdating ignored)',
  $$SELECT t_entry(u(1156), u(21), u(23), 1000)$$,
  $$INSERT INTO capital_movements (id, funding_account_id, kind, amount, effective_on, journal_entry_id, created_at)
    VALUES (u(818), u(304), 'contribution', 1000, current_date, u(1156), '2000-01-01')$$);
SELECT t_true('timing: backdated recorded time was replaced with the real one',
  $$(SELECT created_at FROM capital_movements WHERE id = u(818)) > (SELECT max(recorded_at) FROM deal_sales)$$);
SELECT t_err('funding: account cannot have both an investor and a parent portfolio', 'funding_accounts_check',
  $$INSERT INTO funding_accounts (deal_id, investor_id, parent_portfolio_id) VALUES (u(201), u(1), u(11))$$);
SELECT t_err('funding: investor joins a portfolio only once', 'funding_portfolio_investor_uq',
  $$INSERT INTO funding_accounts (portfolio_id, investor_id) VALUES (u(11), u(1))$$);

-- Overspending
SELECT t_err('overspend: P1 cannot invest more than its cash (1,000,000 > 405,000)', 'portfolio cash would be',
  $$SELECT t_move(NULL, u(303), 'contribution', 1000000)$$);
SELECT t_err('overspend: I2 cannot withdraw more than contributed (800,000 > 700,000)', 'net capital would be',
  $$SELECT t_move(NULL, u(302), 'withdrawal', 800000)$$);
SELECT t_err('overspend: I1 cannot withdraw cash the portfolio has invested (500,000 > 405,000 cash)', 'portfolio cash would be',
  $$SELECT t_move(NULL, u(301), 'withdrawal', 500000)$$);
SELECT t_err('overspend: deal cannot return more capital than P1 holds in it', 'net capital would be',
  $$SELECT t_move(NULL, u(303), 'return_of_capital', 2000000)$$);
SELECT t_err('overspend: P1 cannot be closed while it holds cash', 'cannot close',
  $$UPDATE portfolios SET status = 'closed' WHERE id = u(11)$$);
SELECT t_ok('overspend: empty P2 can be closed', $$UPDATE portfolios SET status = 'closed' WHERE id = u(12)$$);
SELECT t_err('overspend: closed portfolio accepts no money', 'is closed',
  $$SELECT t_move(NULL, u(307), 'contribution', 1000)$$);

-- ---------------------------------------------------------------------------
-- Other expenses
-- ---------------------------------------------------------------------------
SELECT t_ok('expense: survey cost 15,000 recorded against parcel A', $$SELECT t_cost(u(901), u(201), 15000, u(27), 'survey', u(111))$$);
SELECT t_err('journal amount: expense backed by a smaller cash payment rejected', 'pays 1.00 in cash but the cost is 1000.00',
  $$SELECT t_entry(u(1157), u(26), u(21), 1)$$,
  $$INSERT INTO deal_costs (deal_id, category, amount, incurred_on, journal_entry_id) VALUES (u(201), 'legal', 1000, current_date, u(1157))$$);
SELECT t_err('expense: must be on the deal''s land or one of its parcels', 'is not the land of deal',
  $$SELECT t_cost(NULL, u(207), 100, u(26), 'survey', u(101))$$);
SELECT t_err('expense: cannot exceed deal cash (D4 has 0)', 'deal cash would be',
  $$SELECT t_cost(NULL, u(204), 1)$$);
SELECT t_err('expense: recorded cost cannot be edited', 'cannot be changed',
  $$UPDATE deal_costs SET amount = 1 WHERE id = u(901)$$);
SELECT t_err('expense: recorded cost cannot be deleted', 'cannot be deleted',
  $$DELETE FROM deal_costs WHERE id = u(901)$$);
SELECT t_err('expense: cost cannot be voided before its journal entry is reversed', 'reverse its journal entry',
  $$UPDATE deal_costs SET status = 'voided' WHERE id = u(901)$$);
SELECT t_ok('expense: mistaken cost reversed and voided',
  $$SELECT t_cost(u(902), u(201), 1000)$$,
  $$SELECT t_reverse(gen_random_uuid(), (SELECT journal_entry_id FROM deal_costs WHERE id = u(902)))$$,
  $$UPDATE deal_costs SET status = 'voided' WHERE id = u(902)$$);

-- ---------------------------------------------------------------------------
-- Accounting
-- ---------------------------------------------------------------------------
SELECT t_err('journal: unbalanced entry cannot be posted', 'debits 100.00, credits 90.00',
  $$INSERT INTO journal_entries (id, occurred_on, description) VALUES (u(1210), current_date, 'unbalanced')$$,
  $$INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit) VALUES (u(1210), u(21), 100)$$,
  $$INSERT INTO journal_lines (journal_entry_id, ledger_account_id, credit) VALUES (u(1210), u(23), 90)$$,
  $$UPDATE journal_entries SET status = 'posted', posted_at = now(), approved_by = u(9999) WHERE id = u(1210)$$);
SELECT t_err('journal: single-line entry cannot be posted', 'at least two lines',
  $$INSERT INTO journal_entries (id, occurred_on, description) VALUES (u(1211), current_date, 'one line')$$,
  $$INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit) VALUES (u(1211), u(21), 100)$$,
  $$UPDATE journal_entries SET status = 'posted', posted_at = now(), approved_by = u(9999) WHERE id = u(1211)$$);
SELECT t_err('journal: posting requires approver and posting time', 'journal_entries_posting_recorded',
  $$INSERT INTO journal_entries (occurred_on, description, status) VALUES (current_date, 'no approver', 'posted')$$);
SELECT t_err('journal: line cannot be both debit and credit', 'journal_lines_check',
  $$INSERT INTO journal_entries (id, occurred_on, description) VALUES (u(1212), current_date, 'bad line')$$,
  $$INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit, credit) VALUES (u(1212), u(21), 10, 10)$$);
SELECT t_err('journal: line dimension must match a deal-specific ledger account', 'deal must match',
  $$INSERT INTO journal_entries (id, occurred_on, description) VALUES (u(1213), current_date, 'wrong deal')$$,
  $$INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit, deal_id) VALUES (u(1213), u(27), 10, u(202))$$);
SELECT t_ok('journal: balanced entry posted',
  $$SELECT t_entry(u(1201), u(21), u(23), 1000)$$);
SELECT t_err('journal: posted entry cannot be edited', 'posted entries cannot be edited',
  $$UPDATE journal_entries SET description = 'changed' WHERE id = u(1201)$$);
SELECT t_err('journal: posted entry lines cannot be added', 'only be changed while the entry is a draft',
  $$INSERT INTO journal_lines (journal_entry_id, ledger_account_id, debit) VALUES (u(1201), u(21), 5)$$);
SELECT t_err('journal: posted entry lines cannot be changed', 'only be changed while the entry is a draft',
  $$UPDATE journal_lines SET debit = 2000 WHERE journal_entry_id = u(1201) AND debit > 0$$);
SELECT t_err('journal: posted entry cannot be deleted', 'only draft entries can be deleted',
  $$DELETE FROM journal_entries WHERE id = u(1201)$$);
SELECT t_err('journal: cannot mark reversed without a posted reversal', 'post a reversing entry',
  $$UPDATE journal_entries SET status = 'reversed' WHERE id = u(1201)$$);
SELECT t_err('journal: reversal must exactly offset the original', 'exactly offset',
  $$SELECT t_entry(u(1202), u(23), u(21), 50, true, u(1201))$$);
SELECT t_ok('journal: exact reversal posted and original marked reversed',
  $$SELECT t_reverse(u(1203), u(1201))$$);
SELECT t_err('journal: an entry cannot be reversed twice', 'only a posted entry can be reversed',
  $$SELECT t_reverse(u(1204), u(1201))$$);
SELECT t_err('journal: a draft entry cannot be reversed', 'only a posted entry can be reversed',
  $$SELECT t_entry(u(1205), u(21), u(23), 10, false)$$,
  $$SELECT t_reverse(u(1206), u(1205))$$);

-- ---------------------------------------------------------------------------
-- Profit, calculated separately for each completed sale
--   RD2 u(702) whole land L2: 1,500,000 - 1,075,000 = 425,000; office fee 106,250; distributable 318,750
--   RA  u(701) parcel A:        400,000 -   322,500 - survey 15,000 = 62,500; fee 15,625; distributable 46,875;
--                               returnable capital 322,500 + 15,000 = 337,500
--   RB1 u(708) parcel B1:       250,000 -   215,000 = 35,000;  fee  8,750; distributable  26,250
--   RB2 u(709) parcel B2:       260,000 -   215,000 = 45,000;  fee 11,250; distributable  33,750
--   RC  u(703) parcel C:        720,000 -   322,500 = 397,500; fee 99,375; distributable 298,125
--   R4  u(704) whole land L4:   450,000 -   537,500 = -87,500 (loss); fee 0; distributable 0; capital back 450,000
-- ---------------------------------------------------------------------------
SELECT t_err('realization: must be created as draft', 'must be created as draft',
  $$INSERT INTO profit_realizations (deal_id, deal_sale_id, realized_on, status) VALUES (u(202), u(406), current_date, 'approved')$$);
SELECT t_ok('realization: worked example (whole land) approved',
  $$SELECT t_realize(u(702), u(202), u(406))$$,
  $$SELECT t_approve_realization(u(702))$$);
SELECT t_true('realization: example = sale 1,500,000, acquisition 1,075,000, profit 425,000, office fee 106,250, distributable 318,750',
  $$(SELECT (sale_proceeds, acquisition_cost, expenses, profit_before_fee, office_fee, net_profit, distributable_profit, returnable_capital)
       = (1500000.00, 1075000.00, 0.00, 425000.00, 106250.00, 318750.00, 318750.00, 1075000.00)
       FROM profit_realizations WHERE id = u(702))$$);
SELECT t_true('realization: office fee is exactly 25% and distributable profit exactly 75% of profit',
  $$(SELECT office_fee = profit_before_fee * 0.25 AND distributable_profit = profit_before_fee * 0.75
       FROM profit_realizations WHERE id = u(702))$$);
SELECT t_err('realization: office fee charged only once per sale (one realization per sale)', 'profit_realizations_deal_sale_id_key',
  $$SELECT t_realize(u(710), u(202), u(406))$$);
SELECT t_err('realization: sale must belong to the realization''s deal', 'profit_realizations_sale_fk',
  $$SELECT t_realize(u(711), u(202), u(401))$$);
SELECT t_err('realization: a voided sale has no profit', 'completed sale',
  $$SELECT t_realize(u(711), u(201), u(404))$$);
SELECT t_ok('realization: RA drafted for parcel A', $$SELECT t_realize(u(701), u(201), u(401))$$);
SELECT t_err('realization: expense allocations cannot be entered by hand', 'allocations are made automatically',
  $$INSERT INTO realization_costs (realization_id, deal_id, deal_cost_id, amount) VALUES (u(701), u(201), u(901), 1)$$);
SELECT t_err('realization: a closing realization has no sale', 'profit_realizations_kind_sale',
  $$INSERT INTO profit_realizations (deal_id, kind, deal_sale_id, realized_on) VALUES (u(201), 'closing', u(402), current_date)$$);
SELECT t_err('realization: closing not allowed while sales still lack approved profit', 'approve the profit on every sale',
  $$SELECT t_close(u(712), u(201))$$, $$SELECT t_approve_realization(u(712))$$);
SELECT t_err('realization: a sale with a realization cannot be voided', 'included in a profit realization',
  $$UPDATE deal_sales SET status = 'voided' WHERE id = u(401)$$);
SELECT t_err('realization: deal cannot be settled with unrealized sales', 'every sale and expense',
  $$UPDATE deals SET status = 'settled' WHERE id = u(201)$$);
SELECT t_ok('realization: RA approved', $$SELECT t_approve_realization(u(701))$$);
SELECT t_true('realization: parcel A gets 30% of acquisition cost (322,500); profit 62,500; fee 15,625; distributable 46,875',
  $$(SELECT (sale_proceeds, acquisition_cost, expenses, profit_before_fee, office_fee, distributable_profit, returnable_capital)
       = (400000.00, 322500.00, 15000.00, 62500.00, 15625.00, 46875.00, 337500.00)
       FROM profit_realizations WHERE id = u(701))$$);
SELECT t_err('realization: approved realization cannot be changed', 'cannot be changed',
  $$UPDATE profit_realizations SET realized_on = current_date - 1 WHERE id = u(701)$$);
SELECT t_err('realization: approved realization cannot be deleted', 'cannot be deleted',
  $$DELETE FROM profit_realizations WHERE id = u(701)$$);
SELECT t_err('realization: allocations cannot be removed after approval', 'allocations are made automatically',
  $$DELETE FROM realization_costs WHERE realization_id = u(701)$$);
SELECT t_true('realization: survey on parcel A allocated to A''s sale in full',
  $$(SELECT amount FROM realization_costs WHERE realization_id = u(701) AND deal_cost_id = u(901)) = 15000$$);
SELECT t_err('realization: an allocated expense cannot be voided', 'allocated to a profit realization',
  $$UPDATE deal_costs SET status = 'voided' WHERE id = u(901)$$);
SELECT t_err('realization: office fee rule holds even if the approval trigger is bypassed', 'profit_realizations_office_fee_rule',
  $$ALTER TABLE profit_realizations DISABLE TRIGGER profit_realizations_before_write$$,
  $$UPDATE profit_realizations SET office_fee = 10000 WHERE id = u(701)$$);
SELECT t_ok('realization: RB1, RB2 and RC approved, each sale separately',
  $$SELECT t_realize(u(708), u(201), u(402))$$, $$SELECT t_approve_realization(u(708))$$,
  $$SELECT t_realize(u(709), u(201), u(403))$$, $$SELECT t_approve_realization(u(709))$$,
  $$SELECT t_realize(u(703), u(201), u(405))$$, $$SELECT t_approve_realization(u(703))$$);
SELECT t_true('realization: sub-parcel B1 gets 20% of acquisition cost (215,000); profit 35,000; fee 8,750',
  $$(SELECT (acquisition_cost, profit_before_fee, office_fee, distributable_profit) = (215000.00, 35000.00, 8750.00, 26250.00)
       FROM profit_realizations WHERE id = u(708))$$);
SELECT t_true('realization: parcel B2 profit 45,000; fee 11,250; distributable 33,750',
  $$(SELECT (acquisition_cost, profit_before_fee, office_fee, distributable_profit) = (215000.00, 45000.00, 11250.00, 33750.00)
       FROM profit_realizations WHERE id = u(709))$$);
SELECT t_true('realization: parcel C (resold) profit 397,500; fee 99,375; distributable 298,125',
  $$(SELECT (acquisition_cost, profit_before_fee, office_fee, distributable_profit) = (322500.00, 397500.00, 99375.00, 298125.00)
       FROM profit_realizations WHERE id = u(703))$$);
SELECT t_true('realization: parcel acquisition costs add up to L1''s 1,075,000',
  $$(SELECT sum(acquisition_cost) FROM profit_realizations WHERE deal_id = u(201)) = 1075000$$);
SELECT t_ok('realization: D4 land sold at a loss and R4 approved',
  $$SELECT t_sale(u(420), u(204), u(106), 450000, u(1120))$$,
  $$SELECT t_realize(u(704), u(204), u(420))$$,
  $$SELECT t_approve_realization(u(704))$$);
SELECT t_true('realization: no office fee on a loss; nothing distributable; 450,000 capital returnable',
  $$(SELECT (acquisition_cost, profit_before_fee, office_fee, distributable_profit, returnable_capital)
       = (537500.00, -87500.00, 0.00, 0.00, 450000.00)
       FROM profit_realizations WHERE id = u(704))$$);
SELECT t_err('realization: needs the land purchase (with tax and Dalalah) recorded', 'record the land purchase',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(108), 'Khobar', '77', '1', 200000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name, status) VALUES (u(206), u(108), 'Khobar 77/1', 'active')$$,
  $$SELECT t_sale(u(421), u(206), u(108), 300000, gen_random_uuid())$$,
  $$SELECT t_realize(u(707), u(206), u(421))$$,
  $$SELECT t_approve_realization(u(707))$$);
SELECT t_err('realization: a sold parcel needs an allocated purchase price', 'allocated purchase price',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(108), 'Khobar', '77', '1', 200000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name, status) VALUES (u(206), u(108), 'Khobar 77/1', 'active')$$,
  $$INSERT INTO funding_accounts (id, deal_id, investor_id) VALUES (u(308), u(206), u(3))$$,
  $$SELECT t_move(NULL, u(308), 'contribution', 215000)$$,
  $$SELECT t_purchase(u(206), u(108))$$,
  $$SELECT t_parcel(u(181), u(108), '1-A')$$,
  $$SELECT t_sale(u(421), u(206), u(181), 120000, gen_random_uuid())$$,
  $$SELECT t_realize(u(707), u(206), u(421))$$,
  $$SELECT t_approve_realization(u(707))$$);

-- ---------------------------------------------------------------------------
-- Expenses allocated across parcels, and expenses paid after the last sale (L5 / D5)
--   L5 400,000 (acquisition 430,000) -> Q1 u(131) 100,000 (25%), Q2 u(132) 300,000 (75%)
--   fencing 8,000 on the whole land: Q1 carries 2,000, Q2 carries 6,000
--   RQ1 u(721): 150,000 - 107,500 - 2,000 = 40,500; office fee 10,125; distributable 30,375
--   legal fee 1,000 on Q1 paid after RQ1 was approved -> booked by the closing realization u(723)
--   RQ2 u(722): 200,000 - 322,500 - 6,000 = -128,500 (loss); no office fee
-- ---------------------------------------------------------------------------
SELECT t_ok('allocation: L5 subdivided and a whole-land fencing expense of 8,000 recorded',
  $$SELECT t_parcel(u(131), u(109), '5-A', 100000, 500)$$,
  $$SELECT t_parcel(u(132), u(109), '5-B', 300000, 1500)$$,
  $$SELECT t_cost(u(911), u(207), 8000, u(26), 'fencing')$$);
SELECT t_true('allocation: an expense without a land applies to the deal''s whole land',
  $$(SELECT land_id FROM deal_costs WHERE id = u(911)) = u(109)$$);
SELECT t_err('allocation: closing not allowed while land is still unsold', 'all of the deal''s land sold',
  $$SELECT t_close(u(723), u(207))$$, $$SELECT t_approve_realization(u(723))$$);
SELECT t_ok('allocation: Q1 sold for 150,000 and its profit approved',
  $$SELECT t_sale(u(431), u(207), u(131), 150000, gen_random_uuid())$$,
  $$SELECT t_realize(u(721), u(207), u(431))$$,
  $$SELECT t_approve_realization(u(721))$$);
SELECT t_true('allocation: Q1 carries 25% of the fencing (2,000); profit 40,500; office fee 10,125; distributable 30,375',
  $$(SELECT (acquisition_cost, expenses, profit_before_fee, office_fee, distributable_profit)
       = (107500.00, 2000.00, 40500.00, 10125.00, 30375.00) FROM profit_realizations WHERE id = u(721))$$);
SELECT t_ok('allocation: legal fee 1,000 on Q1 paid after its profit was approved',
  $$SELECT t_cost(u(912), u(207), 1000, u(26), 'legal', u(131))$$);
SELECT t_ok('allocation: Q2 sold for 200,000 at a loss and its profit approved',
  $$SELECT t_sale(u(432), u(207), u(132), 200000, gen_random_uuid())$$,
  $$SELECT t_realize(u(722), u(207), u(432))$$,
  $$SELECT t_approve_realization(u(722))$$);
SELECT t_true('allocation: Q2 carries the other 75% of the fencing (6,000) and none of Q1''s legal fee; no office fee on the loss',
  $$(SELECT (acquisition_cost, expenses, profit_before_fee, office_fee, distributable_profit)
       = (322500.00, 6000.00, -128500.00, 0.00, 0.00) FROM profit_realizations WHERE id = u(722))$$);
SELECT t_true('allocation: the fencing is fully allocated (2,000 + 6,000), never more',
  $$(SELECT sum(amount) FROM realization_costs WHERE deal_cost_id = u(911)) = 8000 AND cost_unallocated(u(911)) = 0$$);
SELECT t_err('allocation: deal cannot be settled while an expense is unallocated', 'use a closing realization',
  $$UPDATE deals SET status = 'settled' WHERE id = u(207)$$);
SELECT t_ok('allocation: closing realization books the leftover legal fee', $$SELECT t_close(u(723), u(207))$$, $$SELECT t_approve_realization(u(723))$$);
SELECT t_true('allocation: closing realization = expense 1,000, a loss, no office fee, nothing to distribute',
  $$(SELECT (sale_proceeds, acquisition_cost, expenses, office_fee, net_profit, distributable_profit, returnable_capital)
       = (0.00, 0.00, 1000.00, 0.00, -1000.00, 0.00, 0.00) FROM profit_realizations WHERE id = u(723))$$);
SELECT t_ok('allocation: D5 settles once every expense is allocated', $$UPDATE deals SET status = 'settled' WHERE id = u(207)$$);
SELECT t_err('allocation: no expenses after a deal is settled', 'is settled',
  $$SELECT t_cost(NULL, u(207), 100)$$);

-- ---------------------------------------------------------------------------
-- Deal distributions
--   Worked example, DB2 u(530) pays out RD2 (1,500,000) to I1 (u(305), sole holder):
--     capital 1,075,000 + profit 318,750; office fee 106,250
--   DB1 u(501) pays out RA (400,000):
--     P1 (u(303), 60%): capital 202,500 + profit 28,125 = 230,625   line u(512)
--     I3 (u(304), 40%): capital 135,000 + profit 18,750 = 153,750   line u(511)
--     office fee 15,625                                              line u(513)
-- ---------------------------------------------------------------------------
SELECT t_ok('distribution: worked example - office 106,250, investor profit 318,750 plus capital 1,075,000',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(530), u(202), 1500000, u(702))$$,
  $$SELECT t_line(NULL, u(530), u(305), 'investor', 1075000, 318750)$$,
  $$SELECT t_office(NULL, u(530), 106250)$$,
  $$SELECT t_approve_batch(u(530))$$);
SELECT t_ok('distribution: DB1 drafted with portfolio, investor and office lines',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(501), u(201), 400000, u(701))$$,
  $$SELECT t_line(u(512), u(501), u(303), 'portfolio', 202500, 28125)$$,
  $$SELECT t_line(u(511), u(501), u(304), 'investor', 135000, 18750)$$,
  $$SELECT t_office(u(513), u(501), 15625)$$);
SELECT t_true('distribution: investor_id filled in from the funding account',
  $$(SELECT investor_id FROM distribution_lines WHERE id = u(511)) = u(3)$$);
SELECT t_err('distribution: deal batch cannot pay a portfolio-membership account', 'distribution_lines_account_scope_fk',
  $$SELECT t_line(NULL, u(501), u(301), 'investor', 0, 1)$$);
SELECT t_err('distribution: deal batch cannot pay an account in another deal', 'distribution_lines_account_scope_fk',
  $$SELECT t_line(NULL, u(501), u(305), 'investor', 0, 1)$$);
SELECT t_err('distribution: investor line cannot use a portfolio''s account', 'distribution_lines_account_scope_fk',
  $$INSERT INTO distribution_lines (batch_id, funding_account_id, beneficiary_type, investor_id, amount, profit_component)
    VALUES (u(501), u(303), 'investor', u(1), 1, 1)$$);
SELECT t_err('distribution: line investor must match its funding account', 'distribution_lines_account_investor_fk',
  $$INSERT INTO distribution_lines (batch_id, funding_account_id, beneficiary_type, investor_id, amount, profit_component)
    VALUES (u(501), u(304), 'investor', u(2), 1, 1)$$);
SELECT t_err('distribution: portfolio line needs a funding account', 'distribution_lines_account_required',
  $$INSERT INTO distribution_lines (batch_id, beneficiary_type, amount, profit_component) VALUES (u(501), 'portfolio', 1, 1)$$);
SELECT t_err('distribution: office fee line has no capital or profit component', 'distribution_lines_components',
  $$INSERT INTO distribution_lines (batch_id, beneficiary_type, amount, profit_component) VALUES (u(501), 'office', 1, 1)$$);
SELECT t_err('distribution: amount must equal capital + profit', 'distribution_lines_components',
  $$INSERT INTO distribution_lines (batch_id, funding_account_id, beneficiary_type, amount, profit_component)
    VALUES (u(501), u(304), 'investor', 5, 4)$$);
SELECT t_err('office fee: never charged again in a portfolio batch', 'distribution_lines_office_deal_only',
  $$INSERT INTO distribution_batches (id, portfolio_id, amount, source_line_id) VALUES (u(510), u(11), 100, u(512))$$,
  $$SELECT t_office(NULL, u(510), 100)$$);
SELECT t_err('distribution: deal batch must pay out a profit realization', 'distribution_batches_origin',
  $$INSERT INTO distribution_batches (deal_id, amount) VALUES (u(201), 1)$$);
SELECT t_err('distribution: realization must belong to the batch''s deal', 'distribution_batches_realization_fk',
  $$INSERT INTO distribution_batches (deal_id, amount, profit_realization_id) VALUES (u(201), 1, u(702))$$);
SELECT t_err('distribution: batches start as draft', 'must be created as draft',
  $$INSERT INTO distribution_batches (deal_id, amount, profit_realization_id, status, approved_at) VALUES (u(201), 0, u(701), 'approved', now())$$);
SELECT t_err('distribution: approval requires a journal entry', 'distribution_batches_approval_recorded',
  $$UPDATE distribution_batches SET status = 'approved', approved_at = now() WHERE id = u(501)$$);
SELECT t_err('distribution: lines must add up to the batch amount', 'does not equal batch amount',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(502), u(201), 5000, u(701))$$,
  $$SELECT t_office(NULL, u(502), 4000)$$,
  $$SELECT t_approve_batch(u(502))$$);
SELECT t_err('distribution: realization must be approved first', 'realization must be approved first',
  $$INSERT INTO lands (id, city, plan_number, land_number, purchase_price, status, acquired_on)
    VALUES (u(108), 'Khobar', '77', '1', 200000, 'available', current_date)$$,
  $$INSERT INTO deals (id, land_id, name, status) VALUES (u(206), u(108), 'Khobar 77/1', 'active')$$,
  $$INSERT INTO funding_accounts (id, deal_id, investor_id) VALUES (u(308), u(206), u(3))$$,
  $$SELECT t_move(NULL, u(308), 'contribution', 215000)$$,
  $$SELECT t_purchase(u(206), u(108))$$,
  $$SELECT t_sale(u(421), u(206), u(108), 300000, gen_random_uuid())$$,
  $$SELECT t_realize(u(707), u(206), u(421))$$,
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(505), u(206), 100, u(707))$$,
  $$SELECT t_office(NULL, u(505), 100)$$,
  $$SELECT t_approve_batch(u(505))$$);
SELECT t_err('distribution: no payouts against a draft batch', 'only made against an approved batch',
  $$SELECT t_payout(u(511), 100)$$);
SELECT t_err('profit cap: cannot distribute more than distributable profit (60,000 > 46,875)', 'exceeds distributable profit',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(506), u(201), 60000, u(701))$$,
  $$SELECT t_line(NULL, u(506), u(303), 'portfolio', 0, 36000)$$,
  $$SELECT t_line(NULL, u(506), u(304), 'investor', 0, 24000)$$,
  $$SELECT t_approve_batch(u(506))$$);
SELECT t_err('profit cap: cannot return more capital than the sale allows (400,000 > 337,500)', 'exceeds returnable capital',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(506), u(201), 400000, u(701))$$,
  $$SELECT t_line(NULL, u(506), u(303), 'portfolio', 240000, 0)$$,
  $$SELECT t_line(NULL, u(506), u(304), 'investor', 160000, 0)$$,
  $$SELECT t_approve_batch(u(506))$$);
SELECT t_err('profit cap: cannot pay the office more than 25% (15,625.01 > 15,625)', 'exceeds the office fee',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(506), u(201), 15625.01, u(701))$$,
  $$SELECT t_office(NULL, u(506), 15625.01)$$,
  $$SELECT t_approve_batch(u(506))$$);
SELECT t_err('profit split: profit must follow ownership share (50/50 instead of 60/40)', 'ownership share',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(506), u(201), 46875, u(701))$$,
  $$SELECT t_line(NULL, u(506), u(303), 'portfolio', 0, 23437.50)$$,
  $$SELECT t_line(NULL, u(506), u(304), 'investor', 0, 23437.50)$$,
  $$SELECT t_approve_batch(u(506))$$);
SELECT t_err('profit split: no holder can be left out', 'ownership share',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(506), u(201), 46875, u(701))$$,
  $$SELECT t_line(NULL, u(506), u(303), 'portfolio', 0, 46875)$$,
  $$SELECT t_approve_batch(u(506))$$);
SELECT t_ok('distribution: DB1 approved', $$SELECT t_approve_batch(u(501))$$);
SELECT t_err('distribution: lines frozen after approval', 'only be changed while the batch is a draft',
  $$SELECT t_office(NULL, u(501), 1)$$);
SELECT t_err('distribution: approved batch cannot be edited', 'cannot be edited',
  $$UPDATE distribution_batches SET amount = 90000 WHERE id = u(501)$$);
SELECT t_err('distribution: approved batch cannot return to draft', 'cannot change status',
  $$UPDATE distribution_batches SET status = 'draft' WHERE id = u(501)$$);
SELECT t_err('profit cap: a second batch cannot push RA over its profit (46,876 > 46,875)', 'exceeds distributable profit',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(508), u(201), 1, u(701))$$,
  $$SELECT t_line(NULL, u(508), u(303), 'portfolio', 0, 0.60)$$,
  $$SELECT t_line(NULL, u(508), u(304), 'investor', 0, 0.40)$$,
  $$SELECT t_approve_batch(u(508))$$);
SELECT t_err('office fee: a second batch cannot charge the same sale''s office fee again', 'exceeds the office fee',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(508), u(201), 1, u(701))$$,
  $$SELECT t_office(NULL, u(508), 1)$$,
  $$SELECT t_approve_batch(u(508))$$);
SELECT t_err('journal amount: payout backed by a smaller cash payment rejected', 'pays 1.00 in cash but the payout is 100.00',
  $$SELECT t_entry(u(1158), u(25), u(21), 1)$$,
  $$INSERT INTO payouts (distribution_line_id, amount, paid_on, journal_entry_id) VALUES (u(513), 100, current_date, u(1158))$$);
SELECT t_err('payout: cannot exceed the amount owed', 'would exceed',
  $$SELECT t_payout(u(511), 153750.01)$$);
SELECT t_err('payout: split payouts cannot exceed the amount owed', 'would exceed',
  $$SELECT t_payout(u(511), 100000)$$,
  $$SELECT t_payout(u(511), 53750.01)$$);
SELECT t_err('distribution: batch cannot be marked paid with unpaid lines', 'fully paid',
  $$SELECT t_payout(u(511), 153750)$$,
  $$UPDATE distribution_batches SET status = 'paid' WHERE id = u(501)$$);
SELECT t_err('distribution: approved batch cannot be cancelled before reversing its entry', 'reverse its approval journal entry',
  $$UPDATE distribution_batches SET status = 'cancelled' WHERE id = u(501)$$);
SELECT t_ok('distribution: all DB1 lines paid out, batch marked paid',
  $$SELECT t_payout(u(511), 100000)$$,
  $$SELECT t_payout(u(511), 53750)$$,
  $$SELECT t_payout(u(512), 230625)$$,
  $$SELECT t_payout(u(513), 15625)$$,
  $$UPDATE distribution_batches SET status = 'paid' WHERE id = u(501)$$);
SELECT t_err('payout: none after the batch is paid', 'only made against an approved batch',
  $$SELECT t_payout(u(513), 1)$$);
SELECT t_err('payout: cannot be edited', 'cannot be changed or deleted',
  $$UPDATE payouts SET amount = 1 WHERE distribution_line_id = u(513)$$);
SELECT t_err('payout: cannot be deleted', 'cannot be changed or deleted',
  $$DELETE FROM payouts WHERE distribution_line_id = u(513)$$);
SELECT t_err('payout: its journal entry cannot be reversed', 'compensating',
  $$SELECT t_reverse(gen_random_uuid(), (SELECT journal_entry_id FROM payouts WHERE distribution_line_id = u(513)))$$);
SELECT t_true('distribution: P1 cash includes the 230,625 received from D1 (635,625)', $$portfolio_cash(u(11)) = 635625$$);

-- Loss: D4 can return capital but no profit, and pays no office fee
SELECT t_err('loss: no profit can be distributed from a loss-making sale', 'exceeds distributable profit',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(509), u(204), 1, u(704))$$,
  $$SELECT t_line(NULL, u(509), u(306), 'investor', 0, 1)$$,
  $$SELECT t_approve_batch(u(509))$$);
SELECT t_err('loss: no office fee on a loss-making sale', 'exceeds the office fee',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(509), u(204), 1, u(704))$$,
  $$SELECT t_office(NULL, u(509), 1)$$,
  $$SELECT t_approve_batch(u(509))$$);
SELECT t_ok('loss: the 450,000 sale proceeds returned to I2 as capital',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(509), u(204), 450000, u(704))$$,
  $$SELECT t_line(NULL, u(509), u(306), 'investor', 450000, 0)$$,
  $$SELECT t_approve_batch(u(509))$$);

-- Late investor: I4 joins D1 after its parcels were sold; RB1's profit (26,250) still belongs 60/40 to
-- the holders at the time of that sale.
SELECT t_ok('timing: investor I4 joins D1 with 2,075,000 after all of D1''s sales',
  $$INSERT INTO investors (id, full_name) VALUES (u(4), 'Late Investor')$$,
  $$INSERT INTO funding_accounts (id, deal_id, investor_id) VALUES (u(310), u(201), u(4))$$,
  $$SELECT t_move(NULL, u(310), 'contribution', 2075000)$$);
SELECT t_err('timing: a late investor gets no share of an earlier sale''s profit', 'ownership share',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(541), u(201), 26250, u(708))$$,
  $$SELECT t_line(NULL, u(541), u(303), 'portfolio', 0, 7875)$$,
  $$SELECT t_line(NULL, u(541), u(304), 'investor', 0, 5250)$$,
  $$SELECT t_line(NULL, u(541), u(310), 'investor', 0, 13125)$$,
  $$SELECT t_approve_batch(u(541))$$);
SELECT t_ok('timing: RB1 profit paid 60/40 to the holders at the time of the sale, with the 8,750 office fee',
  $$INSERT INTO distribution_batches (id, deal_id, amount, profit_realization_id) VALUES (u(542), u(201), 35000, u(708))$$,
  $$SELECT t_line(NULL, u(542), u(303), 'portfolio', 0, 15750)$$,
  $$SELECT t_line(NULL, u(542), u(304), 'investor', 0, 10500)$$,
  $$SELECT t_office(NULL, u(542), 8750)$$,
  $$SELECT t_approve_batch(u(542))$$);

-- ---------------------------------------------------------------------------
-- Portfolio distributions: P1 passes DB1's 230,625 (capital 202,500 + profit 28,125) on to its investors,
-- with no second office fee. Shares are measured when parcel A was sold: I1 600,000 / I2 400,000 = 60/40
-- (their later contributions and withdrawals don't count for this sale).
--   I1: capital 121,500 + profit 16,875 = 138,375   line u(521)
--   I2: capital  81,000 + profit 11,250 =  92,250   line u(522)
-- ---------------------------------------------------------------------------
SELECT t_err('portfolio distribution: source must be a portfolio line', 'source line must be a deal payout to portfolio',
  $$INSERT INTO distribution_batches (portfolio_id, amount, source_line_id) VALUES (u(11), 1000, u(511))$$);
SELECT t_err('portfolio distribution: source must pay this portfolio', 'source line must be a deal payout to portfolio',
  $$INSERT INTO distribution_batches (portfolio_id, amount, source_line_id) VALUES (u(12), 1000, u(512))$$);
SELECT t_err('portfolio distribution: portfolio batch needs a source line', 'distribution_batches_origin',
  $$INSERT INTO distribution_batches (portfolio_id, amount) VALUES (u(11), 1000)$$);
SELECT t_err('portfolio distribution: a deal batch cannot have a source line', 'distribution_batches_origin',
  $$INSERT INTO distribution_batches (deal_id, amount, profit_realization_id, source_line_id) VALUES (u(201), 1000, u(701), u(512))$$);
SELECT t_err('portfolio distribution: cannot pass on more than the deal paid', 'deal paid the portfolio only',
  $$INSERT INTO distribution_batches (portfolio_id, amount, source_line_id) VALUES (u(11), 230625.01, u(512))$$);
SELECT t_err('portfolio distribution: cannot pass on more profit than the deal paid (30,000 > 28,125)', 'passes on profit',
  $$INSERT INTO distribution_batches (id, portfolio_id, amount, source_line_id) VALUES (u(503), u(11), 30000, u(512))$$,
  $$SELECT t_line(NULL, u(503), u(301), 'investor', 0, 18000)$$,
  $$SELECT t_line(NULL, u(503), u(302), 'investor', 0, 12000)$$,
  $$SELECT t_approve_batch(u(503))$$);
SELECT t_err('portfolio distribution: profit must follow members'' ownership share', 'ownership share',
  $$INSERT INTO distribution_batches (id, portfolio_id, amount, source_line_id) VALUES (u(503), u(11), 28125, u(512))$$,
  $$SELECT t_line(NULL, u(503), u(301), 'investor', 0, 28125)$$,
  $$SELECT t_approve_batch(u(503))$$);
SELECT t_err('portfolio distribution: cannot pay an investor outside the portfolio', 'distribution_lines_account_scope_fk',
  $$INSERT INTO distribution_batches (id, portfolio_id, amount, source_line_id) VALUES (u(504), u(11), 1000, u(512))$$,
  $$SELECT t_line(NULL, u(504), u(304), 'investor', 0, 1000)$$);
SELECT t_ok('portfolio distribution: P1 passes 230,625 on to I1 and I2 by ownership share, paid in full',
  $$INSERT INTO distribution_batches (id, portfolio_id, amount, source_line_id) VALUES (u(503), u(11), 230625, u(512))$$,
  $$SELECT t_line(u(521), u(503), u(301), 'investor', 121500, 16875)$$,
  $$SELECT t_line(u(522), u(503), u(302), 'investor', 81000, 11250)$$,
  $$SELECT t_approve_batch(u(503))$$,
  $$SELECT t_payout(u(521), 138375)$$,
  $$SELECT t_payout(u(522), 92250)$$,
  $$UPDATE distribution_batches SET status = 'paid' WHERE id = u(503)$$);
SELECT t_true('portfolio distribution: P1 cash back to 405,000 after passing the payout on', $$portfolio_cash(u(11)) = 405000$$);
SELECT t_true('office fee: charged once for parcel A (15,625) even though the deal was portfolio-funded',
  $$(SELECT sum(l.amount) FROM distribution_lines l JOIN distribution_batches b ON b.id = l.batch_id
      WHERE l.beneficiary_type = 'office' AND b.status IN ('approved','paid')
        AND (b.profit_realization_id = u(701) OR b.source_line_id = u(512))) = 15625$$);
SELECT t_err('portfolio distribution: a second batch from the same source would overpay', 'deal paid the portfolio only',
  $$INSERT INTO distribution_batches (portfolio_id, amount, source_line_id) VALUES (u(11), 1, u(512))$$);

-- ---------------------------------------------------------------------------
-- Settling
-- ---------------------------------------------------------------------------
SELECT t_ok('settle: D1 settles once every sale and expense is in an approved realization',
  $$UPDATE deals SET status = 'settled' WHERE id = u(201)$$);

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
\o
\pset footer off
SELECT n AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name AS test,
       left(detail, 130) AS detail
  FROM t_results ORDER BY n;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed, count(*) AS total FROM t_results;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM t_results WHERE NOT ok) THEN
    RAISE EXCEPTION 'schema tests failed';
  END IF;
END $$;
