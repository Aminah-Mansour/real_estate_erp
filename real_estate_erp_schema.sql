-- PostgreSQL schema for a Saudi real estate investment office (land-only).
-- Requires PostgreSQL 15+. All monetary amounts use NUMERIC, never floating point.
--
-- Money flow:
--   investors contribute to shared portfolios or directly to deals; portfolios fund deals;
--   each deal buys one original land (land_purchases), which is sold whole or subdivided into
--   parcels sold separately; every sale is paid in full when recorded (no instalments).
--
-- Tax: the ONLY tax in this system is the 5% land purchase tax, charged once when land is bought.
-- There is no VAT on sales, office fees, Dalalah or anything else, and VAT cannot be recorded as an expense.
--
-- Purchase charges (land purchase only, never on a sale):
--   purchase tax = 5% of the land purchase price (a tax)
--   Dalalah      = 2.5% of the land purchase price: the Land Purchase Brokerage Commission (Dalalah),
--                  Arabic label دلالة شراء الأرض; a commission, not a tax
--   acquisition cost = purchase price + purchase tax + Dalalah
--   A parcel's acquisition cost is the original land's acquisition cost x (parcel's allocated purchase
--   price / original land's purchase price).
--
-- Other expenses are recorded against the land or parcel they apply to. When a sale's profit is approved,
-- each expense on the sold land or on any land it was subdivided from is allocated to it in the same
-- proportion as acquisition cost. Expenses still unallocated once everything is sold (e.g. paid after the
-- last sale) are booked by a closing realization, so every deal can be settled.
--
-- Profit, calculated separately for each completed sale (one profit realization per sale):
--   profit before office fee  = sale amount - acquisition cost of the land or parcel sold - linked expenses
--   office fee                = 25% of profit before office fee, only when it is positive, with no tax added;
--                               charged once per sale, at deal level only (never again in portfolio distributions)
--   distributable profit      = profit before office fee - office fee (75% of a positive profit; 0 on a loss)
--   returnable capital        = acquisition cost + linked expenses, reduced by any loss
--   Example: price 1,000,000 + tax 50,000 + Dalalah 25,000 = 1,075,000; sold for 1,500,000;
--            profit 425,000; office fee 106,250; distributable 318,750.
--   Deal distribution batches pay the office fee, investors' and portfolios' profit (split by ownership
--   share) and their returned capital, capped by the approved realization; portfolio batches pass a
--   portfolio's deal payout on to its investors. Ownership share is measured as of the moment the sale
--   was recorded: capital contributed later earns nothing from that sale.
--
-- Cash:
--   every money movement is backed by a posted journal entry that moves exactly its amount of cash, and
--   can never be edited or deleted;
--   portfolio cash, deal cash and each funding account's capital can never go below zero.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Employees (internal office staff only; investors and buyers never have accounts)
-- One role per employee:
--   admin       manages employees and cities; approves profit, distributions, settlements, closures
--   accountant  prepares and posts financial records (purchases, sales, expenses, capital, payouts,
--               distributions); cannot approve
--   data_entry  maintains lands, investors, portfolios, deals, funding accounts and documents; drafts
--               journal entries; cannot post or approve
--   viewer      read only
-- Every write must name its acting employee with erp_act_as(<id>) at the start of the transaction.
-- Four-eyes rule: whoever prepared a financial record can never post or approve it, whatever their role.
-- ---------------------------------------------------------------------------
CREATE TABLE app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name text NOT NULL CHECK (full_name = btrim(full_name) AND full_name <> ''),
  email text CHECK (email = lower(btrim(email)) AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role text NOT NULL CHECK (role IN ('admin','accountant','data_entry','viewer')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  is_system boolean NOT NULL DEFAULT false,
  CONSTRAINT app_users_email_required CHECK (is_system OR email IS NOT NULL)
);
CREATE UNIQUE INDEX app_users_email_uq ON app_users (email) WHERE email IS NOT NULL;
COMMENT ON TABLE app_users IS 'Internal office employees. Never deleted: disable instead. No customer or investor accounts.';
COMMENT ON COLUMN app_users.is_system IS 'The single built-in system user used by seeds and maintenance; it can never log in.';

-- The built-in system user: data_entry rights only (can never post or approve), cannot log in.
CREATE FUNCTION erp_system_user_id() RETURNS uuid LANGUAGE sql IMMUTABLE AS
$$ SELECT '00000000-0000-0000-0000-000000000001'::uuid $$;
INSERT INTO app_users (id, full_name, email, role, is_system)
VALUES (erp_system_user_id(), 'System', NULL, 'data_entry', true);

-- Groundwork for secure login. Only a password HASH is ever stored (Argon2id, produced by the
-- application); plain passwords never reach the database. Readable only by the erp_auth database role.
CREATE TABLE user_credentials (
  user_id uuid PRIMARY KEY REFERENCES app_users(id),
  password_hash text NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
  password_changed_at timestamptz NOT NULL DEFAULT now(),
  failed_login_count integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
  locked_until timestamptz,
  mfa_enabled boolean NOT NULL DEFAULT false,
  last_login_at timestamptz
);
COMMENT ON TABLE user_credentials IS 'Login credentials (Argon2id hash only). Not visible to the application role; audited without the hash.';

-- ---------------------------------------------------------------------------
-- Parties
-- ---------------------------------------------------------------------------
CREATE TABLE investors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name text NOT NULL,
  contact_phone text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- A closed portfolio accepts no money movements; it can only be closed with no cash and no deal capital.
CREATE TABLE portfolios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Cities (reference data). One row per city: a stable code, the Arabic name shown in the UI and the
-- English name. city_aliases lists every accepted spelling (matched ignoring case and surrounding spaces),
-- so 'جدة' and 'Jeddah' are the same city. Add a city by inserting it here with its aliases.
-- ---------------------------------------------------------------------------
CREATE TABLE cities (
  code text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
  name_ar text NOT NULL UNIQUE CHECK (name_ar = btrim(name_ar) AND name_ar <> ''),
  name_en text NOT NULL UNIQUE CHECK (name_en = btrim(name_en) AND name_en <> '')
);
COMMENT ON TABLE cities IS 'Reference list of cities. name_ar is the name shown in the Arabic UI; name_en in the English UI.';

CREATE TABLE city_aliases (
  alias text PRIMARY KEY CHECK (alias = lower(btrim(alias)) AND alias <> ''),
  city_code text NOT NULL REFERENCES cities(code)
);
COMMENT ON TABLE city_aliases IS 'Accepted spellings of each city, stored lower-case and trimmed.';

INSERT INTO cities (code, name_ar, name_en) VALUES
  ('riyadh',  'الرياض',          'Riyadh'),
  ('jeddah',  'جدة',             'Jeddah'),
  ('makkah',  'مكة المكرمة',     'Makkah'),
  ('madinah', 'المدينة المنورة', 'Madinah'),
  ('dammam',  'الدمام',          'Dammam'),
  ('khobar',  'الخبر',           'Khobar'),
  ('taif',    'الطائف',          'Taif'),
  ('abha',    'أبها',            'Abha');

INSERT INTO city_aliases (alias, city_code)
SELECT lower(name_ar), code FROM cities
UNION SELECT lower(name_en), code FROM cities
UNION SELECT lower(code), code FROM cities
UNION SELECT a, c FROM (VALUES
  ('جده', 'jeddah'), ('jiddah', 'jeddah'), ('jedda', 'jeddah'),
  ('مكة', 'makkah'), ('mecca', 'makkah'), ('makkah al mukarramah', 'makkah'),
  ('المدينة', 'madinah'), ('medina', 'madinah'), ('al madinah', 'madinah'),
  ('al khobar', 'khobar')) AS extra (a, c);

-- ---------------------------------------------------------------------------
-- Lands and parcels
-- ---------------------------------------------------------------------------
-- A land is identified by city + plan number (رقم المخطط) + land number (رقم القطعة). The city may be
-- entered in any accepted spelling; the database resolves it to city_code (used for identity) and stores
-- the city's Arabic name in lands.city.
-- An original land has parent_land_id NULL; subdividing it creates child parcels (which may be
-- subdivided again). Statuses 'sold' and 'partially_sold' are maintained automatically from deal_sales.
CREATE TABLE lands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_land_id uuid,
  city text NOT NULL CHECK (city = btrim(city) AND city <> ''),
  plan_number text NOT NULL CHECK (plan_number = btrim(plan_number) AND plan_number <> ''),
  land_number text NOT NULL CHECK (land_number = btrim(land_number) AND land_number <> ''),
  street text,
  purchase_price numeric(18,2) CHECK (purchase_price > 0),
  sale_price numeric(18,2) CHECK (sale_price > 0),
  area_sqm numeric(14,2) CHECK (area_sqm > 0),
  street_width_m numeric(6,2) CHECK (street_width_m > 0),
  title text,
  status text NOT NULL DEFAULT 'prospective' CHECK (status IN
    ('prospective','available','listed','under_contract','partially_sold','sold','cancelled')),
  acquired_on date,
  created_at timestamptz NOT NULL DEFAULT now(),
  city_code text NOT NULL REFERENCES cities(code),
  CONSTRAINT lands_identity_uq UNIQUE (city_code, plan_number, land_number),
  CONSTRAINT lands_id_city_uq UNIQUE (id, city_code),
  CONSTRAINT lands_parent_fk FOREIGN KEY (parent_land_id, city_code) REFERENCES lands (id, city_code),
  CONSTRAINT lands_not_own_parent CHECK (parent_land_id <> id),
  CONSTRAINT lands_purchase_recorded CHECK (parent_land_id IS NOT NULL OR status IN ('prospective','cancelled')
                                            OR (purchase_price IS NOT NULL AND acquired_on IS NOT NULL)),
  CONSTRAINT lands_parcel_status CHECK (parent_land_id IS NULL OR status NOT IN ('prospective','cancelled'))
);
COMMENT ON COLUMN lands.purchase_price IS
  'Purchase price excluding purchase tax and Dalalah. Original land: price paid. Parcel: its allocated share of the parent''s purchase price, which also allocates the purchase tax and Dalalah (required before profit on its sale can be approved; parcels of one land never total more than the land).';
COMMENT ON COLUMN lands.sale_price IS 'Optional asking price. The actual sale amount is deal_sales.sale_amount.';
COMMENT ON COLUMN lands.area_sqm IS 'Optional area in square metres; parcels of one land never total more than the land.';
COMMENT ON COLUMN lands.street_width_m IS 'Optional width in metres of the street the land faces.';
COMMENT ON COLUMN lands.parent_land_id IS 'Set on parcels created by subdividing a land; never changes after creation.';
COMMENT ON COLUMN lands.city IS 'Arabic city name for the UI (cities.name_ar). Any accepted spelling may be entered; it is normalized on save.';
COMMENT ON COLUMN lands.city_code IS 'Resolved city (cities.code); part of the land''s identity, so all spellings of a city match.';

-- ---------------------------------------------------------------------------
-- Deals (one investment per original land)
-- ---------------------------------------------------------------------------
CREATE TABLE deals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  land_id uuid NOT NULL REFERENCES lands(id),
  name text NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','funding','active','sold','settled','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX deals_one_open_per_land ON deals (land_id) WHERE status <> 'cancelled';
COMMENT ON COLUMN deals.status IS 'settled requires every sale and expense of the deal to be in an approved profit realization.';

-- ---------------------------------------------------------------------------
-- Funding accounts: investor in a portfolio, investor directly in a deal, or portfolio in a deal.
-- scope_* / holder_type are derived so other tables can verify, with plain foreign keys, that they
-- point at an account in the right deal/portfolio and of the right kind.
-- ---------------------------------------------------------------------------
CREATE TABLE funding_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  portfolio_id uuid REFERENCES portfolios(id),
  deal_id uuid REFERENCES deals(id),
  investor_id uuid REFERENCES investors(id),
  parent_portfolio_id uuid REFERENCES portfolios(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  scope_type text GENERATED ALWAYS AS (CASE WHEN deal_id IS NOT NULL THEN 'deal' ELSE 'portfolio' END) STORED,
  scope_id uuid GENERATED ALWAYS AS (COALESCE(deal_id, portfolio_id)) STORED,
  holder_type text GENERATED ALWAYS AS (CASE WHEN investor_id IS NOT NULL THEN 'investor' ELSE 'portfolio' END) STORED,
  CHECK ((portfolio_id IS NOT NULL AND deal_id IS NULL AND investor_id IS NOT NULL AND parent_portfolio_id IS NULL)
      OR (deal_id IS NOT NULL AND portfolio_id IS NULL
          AND ((investor_id IS NOT NULL AND parent_portfolio_id IS NULL)
            OR (investor_id IS NULL AND parent_portfolio_id IS NOT NULL)))),
  CONSTRAINT funding_accounts_scope_uq UNIQUE (id, scope_type, scope_id, holder_type),
  CONSTRAINT funding_accounts_investor_uq UNIQUE (id, investor_id)
);
CREATE UNIQUE INDEX funding_portfolio_investor_uq ON funding_accounts(portfolio_id,investor_id) WHERE portfolio_id IS NOT NULL;
CREATE UNIQUE INDEX funding_deal_investor_uq ON funding_accounts(deal_id,investor_id) WHERE deal_id IS NOT NULL AND investor_id IS NOT NULL;
CREATE UNIQUE INDEX funding_deal_portfolio_uq ON funding_accounts(deal_id,parent_portfolio_id) WHERE parent_portfolio_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- General ledger
-- ---------------------------------------------------------------------------
CREATE TABLE ledger_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  account_type text NOT NULL CHECK (account_type IN ('asset','liability','equity','revenue','expense')),
  is_cash boolean NOT NULL DEFAULT false CHECK (NOT is_cash OR account_type = 'asset'),
  portfolio_id uuid REFERENCES portfolios(id),
  deal_id uuid REFERENCES deals(id),
  investor_id uuid REFERENCES investors(id)
);
COMMENT ON COLUMN ledger_accounts.is_cash IS 'Cash/bank account. A land sale must debit cash accounts by the full sale amount.';

-- Lifecycle: draft (lines editable) -> posted (immutable) -> reversed (only once a posted entry with
-- reverses_entry_id = this entry exactly offsets it). Corrections are made by reversal, never by editing.
CREATE TABLE journal_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_on date NOT NULL,
  description text NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','reversed')),
  source_type text,
  source_id uuid,
  approved_by uuid,
  posted_at timestamptz,
  reverses_entry_id uuid UNIQUE REFERENCES journal_entries(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT journal_entries_not_self_reversal CHECK (reverses_entry_id <> id),
  CONSTRAINT journal_entries_posting_recorded CHECK (status = 'draft' OR (posted_at IS NOT NULL AND approved_by IS NOT NULL))
);

CREATE TABLE journal_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id uuid NOT NULL REFERENCES journal_entries(id),
  ledger_account_id uuid NOT NULL REFERENCES ledger_accounts(id),
  debit numeric(18,2) NOT NULL DEFAULT 0,
  credit numeric(18,2) NOT NULL DEFAULT 0,
  portfolio_id uuid REFERENCES portfolios(id),
  deal_id uuid REFERENCES deals(id),
  investor_id uuid REFERENCES investors(id),
  CHECK (debit >= 0 AND credit >= 0 AND ((debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)))
);

-- ---------------------------------------------------------------------------
-- Capital: contributions, withdrawals, returns of capital, transfers between funding accounts.
-- Recorded movements are permanent; mistakes are corrected with a compensating movement.
-- ---------------------------------------------------------------------------
CREATE TABLE capital_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  funding_account_id uuid NOT NULL REFERENCES funding_accounts(id),
  kind text NOT NULL CHECK (kind IN ('contribution','withdrawal','return_of_capital','transfer_in','transfer_out')),
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  effective_on date NOT NULL,
  transfer_group_id uuid,
  journal_entry_id uuid NOT NULL UNIQUE REFERENCES journal_entries(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT capital_movements_transfer_group CHECK ((kind IN ('transfer_in','transfer_out')) = (transfer_group_id IS NOT NULL))
);
COMMENT ON COLUMN capital_movements.created_at IS
  'Set by the database when recorded (cannot be backdated). Ownership share for a sale counts only movements recorded before the sale.';
COMMENT ON COLUMN capital_movements.journal_entry_id IS
  'Posted entry moving exactly this amount of cash: contributions debit cash, withdrawals and returns credit cash; a transfer leg''s entry totals the amount.';
COMMENT ON COLUMN capital_movements.kind IS
  'withdrawal = investor takes uninvested cash out; return_of_capital = capital repaid outside a distribution batch.';
COMMENT ON COLUMN capital_movements.transfer_group_id IS 'Pairs exactly one transfer_out with one transfer_in of the same amount.';

-- ---------------------------------------------------------------------------
-- Land purchase, expenses and sales
-- ---------------------------------------------------------------------------
-- The purchase charge rules, defined once and used both by land_purchases and by the preview of lands
-- not yet bought: purchase tax 5% (the only tax), Dalalah 2.5% (a commission), rounded to the halala.
CREATE FUNCTION purchase_tax_amount(p_price numeric) RETURNS numeric LANGUAGE sql IMMUTABLE STRICT AS
$$ SELECT round(p_price * 0.05, 2) $$;
CREATE FUNCTION dalalah_amount(p_price numeric) RETURNS numeric LANGUAGE sql IMMUTABLE STRICT AS
$$ SELECT round(p_price * 0.025, 2) $$;
CREATE FUNCTION acquisition_cost_amount(p_price numeric) RETURNS numeric LANGUAGE sql IMMUTABLE STRICT AS
$$ SELECT p_price + purchase_tax_amount(p_price) + dalalah_amount(p_price) $$;
COMMENT ON FUNCTION purchase_tax_amount(numeric) IS 'Purchase tax: 5% of the land purchase price, rounded to the halala.';
COMMENT ON FUNCTION dalalah_amount(numeric) IS 'Land Purchase Brokerage Commission (Dalalah) / دلالة شراء الأرض: 2.5% of the purchase price, rounded to the halala.';
COMMENT ON FUNCTION acquisition_cost_amount(numeric) IS 'Total acquisition cost: purchase price + purchase tax + Dalalah.';

-- Purchase of a deal's land, paid from the deal's cash: once per deal. amount equals lands.purchase_price;
-- purchase tax (5%) and Dalalah (2.5%) are computed here and are the only purchase charges. Its posted
-- journal entry must pay out (credit cash accounts by) exactly total_cost.
CREATE TABLE land_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL UNIQUE REFERENCES deals(id),
  land_id uuid NOT NULL UNIQUE REFERENCES lands(id),
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  purchase_tax numeric(18,2) GENERATED ALWAYS AS (purchase_tax_amount(amount)) STORED,
  dalalah numeric(18,2) GENERATED ALWAYS AS (dalalah_amount(amount)) STORED,
  total_cost numeric(18,2) GENERATED ALWAYS AS (acquisition_cost_amount(amount)) STORED,
  paid_on date NOT NULL,
  journal_entry_id uuid NOT NULL UNIQUE REFERENCES journal_entries(id)
);
COMMENT ON COLUMN land_purchases.amount IS 'Land purchase price (equals lands.purchase_price).';
COMMENT ON COLUMN land_purchases.purchase_tax IS 'Purchase tax: 5% of the purchase price. Charged on purchase only.';
COMMENT ON COLUMN land_purchases.dalalah IS
  'Land Purchase Brokerage Commission (Dalalah) / دلالة شراء الأرض: 2.5% of the purchase price. A commission, not a tax. Charged on purchase only, never on a sale; included in total_cost (acquisition cost).';
COMMENT ON COLUMN land_purchases.total_cost IS 'Acquisition cost: purchase price + purchase tax + Dalalah.';

-- Other deal expenses, paid from the deal's cash, recorded against the land or parcel they apply to
-- (the deal's original land when it applies to the whole land) and allocated to sales automatically.
-- Purchase tax, Dalalah and office fees are computed elsewhere and can never be recorded here; neither can
-- VAT or any other tax. Its posted journal entry pays out exactly the amount in cash.
-- Mistakes: reverse the journal entry and void the cost (only while none of it has been allocated).
CREATE TABLE deal_costs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES deals(id),
  land_id uuid NOT NULL REFERENCES lands(id),
  category text NOT NULL,
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  incurred_on date NOT NULL,
  status text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded','voided')),
  journal_entry_id uuid NOT NULL UNIQUE REFERENCES journal_entries(id),
  CONSTRAINT deal_costs_id_deal_uq UNIQUE (id, deal_id),
  CONSTRAINT deal_costs_not_computed_charge CHECK (lower(btrim(category)) NOT IN
    ('land_purchase','purchase_price','purchase_tax','tax','dalalah','brokerage','office_fee','office_fees',
     'vat','value_added_tax','sales_tax'))
);
COMMENT ON COLUMN deal_costs.land_id IS
  'Land or parcel the expense applies to; defaults to the deal''s original land. Must be that land or one of its parcels.';

-- One row per sold land or parcel. A sale is paid in full when recorded: its posted journal entry
-- must debit cash accounts by exactly sale_amount. Mistakes are fixed by reversing the journal entry
-- and voiding the sale; the land can then be sold again.
CREATE TABLE deal_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES deals(id),
  land_id uuid NOT NULL REFERENCES lands(id),
  sale_amount numeric(18,2) NOT NULL CHECK (sale_amount > 0),
  sold_on date NOT NULL,
  buyer_name text NOT NULL,
  payment_reference text NOT NULL,
  status text NOT NULL DEFAULT 'completed' CHECK (status IN ('completed','voided')),
  journal_entry_id uuid UNIQUE REFERENCES journal_entries(id),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT deal_sales_id_deal_uq UNIQUE (id, deal_id),
  CONSTRAINT deal_sales_completed_has_entry CHECK (status <> 'completed' OR journal_entry_id IS NOT NULL)
);
CREATE UNIQUE INDEX deal_sales_one_per_land ON deal_sales (land_id) WHERE status = 'completed';
COMMENT ON COLUMN deal_sales.sold_on IS 'Sale date, which is also the date the full payment was received.';
COMMENT ON COLUMN deal_sales.recorded_at IS
  'Set by the database when recorded (cannot be backdated). Ownership shares for this sale''s profit are measured at this moment.';

-- ---------------------------------------------------------------------------
-- Profit realizations. kind 'sale': approved profit on ONE completed sale (profit is calculated
-- separately for each sale, so the office fee can only ever be charged once per sale). kind 'closing':
-- books expenses left unallocated once all of the deal's land is sold (a loss; no fee, nothing to
-- distribute). On approval the database allocates expenses (realization_costs) and computes and freezes
-- every figure. Approved realizations never change.
-- ---------------------------------------------------------------------------
CREATE TABLE profit_realizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES deals(id),
  kind text NOT NULL DEFAULT 'sale' CHECK (kind IN ('sale','closing')),
  deal_sale_id uuid UNIQUE,
  realized_on date NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved')),
  sale_proceeds numeric(18,2),
  acquisition_cost numeric(18,2),
  expenses numeric(18,2),
  office_fee numeric(18,2),
  profit_before_fee numeric(18,2) GENERATED ALWAYS AS (sale_proceeds - acquisition_cost - expenses) STORED,
  net_profit numeric(18,2) GENERATED ALWAYS AS (sale_proceeds - acquisition_cost - expenses - office_fee) STORED,
  distributable_profit numeric(18,2) GENERATED ALWAYS AS
    (greatest(sale_proceeds - acquisition_cost - expenses - office_fee, 0)) STORED,
  returnable_capital numeric(18,2) GENERATED ALWAYS AS
    (greatest(acquisition_cost + expenses + least(sale_proceeds - acquisition_cost - expenses - office_fee, 0), 0)) STORED,
  approved_at timestamptz,
  approved_by uuid,
  journal_entry_id uuid UNIQUE REFERENCES journal_entries(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profit_realizations_id_deal_uq UNIQUE (id, deal_id),
  CONSTRAINT profit_realizations_sale_fk FOREIGN KEY (deal_sale_id, deal_id) REFERENCES deal_sales (id, deal_id),
  CONSTRAINT profit_realizations_kind_sale CHECK ((kind = 'sale') = (deal_sale_id IS NOT NULL)),
  CONSTRAINT profit_realizations_approval_recorded CHECK (status = 'draft' OR (
    sale_proceeds IS NOT NULL AND acquisition_cost IS NOT NULL AND expenses IS NOT NULL AND office_fee IS NOT NULL
    AND approved_at IS NOT NULL AND approved_by IS NOT NULL)),
  CONSTRAINT profit_realizations_office_fee_rule CHECK (office_fee IS NULL
    OR office_fee = CASE WHEN sale_proceeds - acquisition_cost - expenses > 0
                         THEN round((sale_proceeds - acquisition_cost - expenses) * 0.25, 2) ELSE 0 END)
);
COMMENT ON COLUMN profit_realizations.sale_proceeds IS 'The sale amount, received in full (no sale-side purchase tax or Dalalah).';
COMMENT ON COLUMN profit_realizations.acquisition_cost IS 'Acquisition cost (price + 5% tax + 2.5% Dalalah) allocated to the land or parcel sold.';
COMMENT ON COLUMN profit_realizations.expenses IS 'Other expenses allocated to this sale (or, for a closing realization, left over), per realization_costs.';
COMMENT ON COLUMN profit_realizations.office_fee IS 'Office fee: 25% of a positive profit before office fee; 0 when there is no profit.';
COMMENT ON COLUMN profit_realizations.net_profit IS 'Profit after office fee (negative = loss).';
COMMENT ON COLUMN profit_realizations.distributable_profit IS 'Profit investors and portfolios may receive: 75% of a positive profit before office fee, else 0.';
COMMENT ON COLUMN profit_realizations.returnable_capital IS 'Capital that may be returned: acquisition cost + expenses, reduced by any loss.';

-- Expense allocations, written only by realization approval: how much of each expense a realization
-- carries. An expense is never allocated beyond its amount; settling requires it fully allocated.
CREATE TABLE realization_costs (
  realization_id uuid NOT NULL,
  deal_id uuid NOT NULL,
  deal_cost_id uuid NOT NULL,
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  PRIMARY KEY (realization_id, deal_cost_id),
  CONSTRAINT realization_costs_realization_fk FOREIGN KEY (realization_id, deal_id)
    REFERENCES profit_realizations (id, deal_id) ON DELETE CASCADE,
  CONSTRAINT realization_costs_cost_fk FOREIGN KEY (deal_cost_id, deal_id) REFERENCES deal_costs (id, deal_id)
);
CREATE INDEX realization_costs_cost_idx ON realization_costs (deal_cost_id);

-- ---------------------------------------------------------------------------
-- Distributions
-- A deal batch pays out an approved profit realization: the office fee, plus profit and returned
-- capital to direct investors and investing portfolios. A portfolio batch passes a portfolio's deal
-- payout (source_line_id) on to the portfolio's investors. Office fees never appear in portfolio batches.
-- Lines are editable only while the batch is a draft.
-- ---------------------------------------------------------------------------
CREATE TABLE distribution_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid REFERENCES deals(id),
  portfolio_id uuid REFERENCES portfolios(id),
  amount numeric(18,2) NOT NULL CHECK (amount >= 0),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','paid','cancelled')),
  profit_realization_id uuid,
  source_line_id uuid,
  approved_at timestamptz,
  journal_entry_id uuid UNIQUE REFERENCES journal_entries(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  scope_type text GENERATED ALWAYS AS (CASE WHEN deal_id IS NOT NULL THEN 'deal' ELSE 'portfolio' END) STORED,
  scope_id uuid GENERATED ALWAYS AS (COALESCE(deal_id, portfolio_id)) STORED,
  CHECK ((deal_id IS NOT NULL)::int + (portfolio_id IS NOT NULL)::int = 1),
  CONSTRAINT distribution_batches_scope_uq UNIQUE (id, scope_type, scope_id),
  CONSTRAINT distribution_batches_realization_fk FOREIGN KEY (profit_realization_id, deal_id)
    REFERENCES profit_realizations (id, deal_id),
  CONSTRAINT distribution_batches_origin CHECK (
    (deal_id IS NOT NULL AND profit_realization_id IS NOT NULL AND source_line_id IS NULL)
    OR (portfolio_id IS NOT NULL AND source_line_id IS NOT NULL AND profit_realization_id IS NULL)),
  CONSTRAINT distribution_batches_approval_recorded CHECK (status IN ('draft','cancelled')
                                                           OR (approved_at IS NOT NULL AND journal_entry_id IS NOT NULL))
);
COMMENT ON COLUMN distribution_batches.journal_entry_id IS 'Entry recording the distribution payable when the batch is approved.';

CREATE TABLE distribution_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES distribution_batches(id),
  investor_id uuid REFERENCES investors(id),
  funding_account_id uuid REFERENCES funding_accounts(id),
  beneficiary_type text NOT NULL CHECK (beneficiary_type IN ('investor','portfolio','office')),
  amount numeric(18,2) NOT NULL CHECK (amount >= 0),
  capital_component numeric(18,2) NOT NULL DEFAULT 0 CHECK (capital_component >= 0),
  profit_component numeric(18,2) NOT NULL DEFAULT 0 CHECK (profit_component >= 0),
  scope_type text NOT NULL,   -- copied from the batch by trigger
  scope_id uuid NOT NULL,     -- copied from the batch by trigger
  CONSTRAINT distribution_lines_components CHECK (
    (beneficiary_type = 'office' AND capital_component = 0 AND profit_component = 0)
    OR (beneficiary_type <> 'office' AND amount = capital_component + profit_component)),
  CONSTRAINT distribution_lines_office_deal_only CHECK (beneficiary_type <> 'office' OR scope_type = 'deal'),
  CONSTRAINT distribution_lines_batch_scope_fk FOREIGN KEY (batch_id, scope_type, scope_id)
    REFERENCES distribution_batches (id, scope_type, scope_id),
  CONSTRAINT distribution_lines_account_scope_fk FOREIGN KEY (funding_account_id, scope_type, scope_id, beneficiary_type)
    REFERENCES funding_accounts (id, scope_type, scope_id, holder_type),
  CONSTRAINT distribution_lines_account_investor_fk FOREIGN KEY (funding_account_id, investor_id)
    REFERENCES funding_accounts (id, investor_id),
  CONSTRAINT distribution_lines_account_required CHECK ((beneficiary_type = 'office') = (funding_account_id IS NULL)),
  CONSTRAINT distribution_lines_investor_required CHECK ((beneficiary_type = 'investor') = (investor_id IS NOT NULL))
);
COMMENT ON COLUMN distribution_lines.amount IS 'Office lines: office fee paid. Other lines: capital_component + profit_component.';

ALTER TABLE distribution_batches
  ADD CONSTRAINT distribution_batches_source_line_fk FOREIGN KEY (source_line_id) REFERENCES distribution_lines(id);

-- Payouts are permanent; each is backed by a posted journal entry.
CREATE TABLE payouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  distribution_line_id uuid NOT NULL REFERENCES distribution_lines(id),
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  paid_on date NOT NULL,
  reference text,
  journal_entry_id uuid NOT NULL UNIQUE REFERENCES journal_entries(id)
);

-- ---------------------------------------------------------------------------
-- Documents and audit
-- ---------------------------------------------------------------------------
CREATE TABLE documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  object_key text NOT NULL,
  file_name text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);

-- Append-only audit trail, written only by the erp_audit trigger on every audited table.
-- action: create, update, delete, or the business step of a status change (post, reverse, approve,
-- pay, cancel, void, settle, close, disable, status_change), role_change, credential_*.
CREATE TABLE audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid REFERENCES app_users(id),
  entity_type text NOT NULL,
  entity_id text NOT NULL,
  action text NOT NULL,
  old_values jsonb,
  new_values jsonb,
  transaction_id bigint NOT NULL DEFAULT txid_current(),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX audit_events_entity_idx ON audit_events (entity_type, entity_id);
CREATE INDEX audit_events_actor_idx ON audit_events (actor_id);
COMMENT ON TABLE audit_events IS 'Append-only: who did what, when, with values before and after. Cannot be edited or deleted.';

-- ---------------------------------------------------------------------------
-- Indexes on foreign-key columns (PostgreSQL does not create these automatically)
-- ---------------------------------------------------------------------------
CREATE INDEX lands_parent_idx ON lands (parent_land_id);
CREATE INDEX lands_city_idx ON lands (city_code);
CREATE INDEX city_aliases_city_idx ON city_aliases (city_code);
CREATE INDEX deals_land_idx ON deals (land_id);
CREATE INDEX funding_accounts_deal_idx ON funding_accounts (deal_id);
CREATE INDEX funding_accounts_investor_idx ON funding_accounts (investor_id);
CREATE INDEX funding_accounts_parent_portfolio_idx ON funding_accounts (parent_portfolio_id);
CREATE INDEX ledger_accounts_portfolio_idx ON ledger_accounts (portfolio_id);
CREATE INDEX ledger_accounts_deal_idx ON ledger_accounts (deal_id);
CREATE INDEX ledger_accounts_investor_idx ON ledger_accounts (investor_id);
CREATE INDEX journal_lines_entry_idx ON journal_lines (journal_entry_id);
CREATE INDEX journal_lines_account_idx ON journal_lines (ledger_account_id);
CREATE INDEX journal_lines_portfolio_idx ON journal_lines (portfolio_id);
CREATE INDEX journal_lines_deal_idx ON journal_lines (deal_id);
CREATE INDEX journal_lines_investor_idx ON journal_lines (investor_id);
CREATE INDEX capital_movements_account_idx ON capital_movements (funding_account_id);
CREATE INDEX capital_movements_transfer_idx ON capital_movements (transfer_group_id);
CREATE INDEX land_purchases_land_idx ON land_purchases (land_id);
CREATE INDEX deal_costs_deal_idx ON deal_costs (deal_id);
CREATE INDEX deal_sales_deal_idx ON deal_sales (deal_id);
CREATE INDEX deal_sales_land_idx ON deal_sales (land_id);
CREATE INDEX profit_realizations_deal_idx ON profit_realizations (deal_id);
CREATE INDEX distribution_batches_deal_idx ON distribution_batches (deal_id);
CREATE INDEX distribution_batches_portfolio_idx ON distribution_batches (portfolio_id);
CREATE INDEX distribution_batches_realization_idx ON distribution_batches (profit_realization_id);
CREATE INDEX distribution_batches_source_idx ON distribution_batches (source_line_id);
CREATE INDEX distribution_lines_batch_idx ON distribution_lines (batch_id);
CREATE INDEX distribution_lines_investor_idx ON distribution_lines (investor_id);
CREATE INDEX distribution_lines_account_idx ON distribution_lines (funding_account_id);
CREATE INDEX payouts_line_idx ON payouts (distribution_line_id);

-- ---------------------------------------------------------------------------
-- Read-only views
-- ---------------------------------------------------------------------------
-- Purchase charges for every original land with a purchase price. For a land already bought, the figures
-- come from its recorded purchase; for a land not yet bought they are a preview computed by the same
-- rule functions. A preview creates no purchase, payment or accounting record.
CREATE VIEW land_acquisition_preview AS
SELECT l.id AS land_id,
       l.city,
       l.city_code,
       c.name_en AS city_name_en,
       l.plan_number,
       l.land_number,
       l.status,
       l.purchase_price,
       coalesce(lp.purchase_tax, purchase_tax_amount(l.purchase_price)) AS purchase_tax,
       coalesce(lp.dalalah, dalalah_amount(l.purchase_price)) AS dalalah,
       coalesce(lp.total_cost, acquisition_cost_amount(l.purchase_price)) AS total_acquisition_cost,
       lp.id IS NOT NULL AS purchase_recorded
  FROM lands l
  JOIN cities c ON c.code = l.city_code
  LEFT JOIN land_purchases lp ON lp.land_id = l.id
 WHERE l.parent_land_id IS NULL AND l.purchase_price IS NOT NULL;
COMMENT ON VIEW land_acquisition_preview IS
  'Purchase tax, Dalalah and total acquisition cost per original land: recorded figures once purchased, otherwise a preview.';

-- ===========================================================================
-- Balances
-- ===========================================================================

-- +1 when a movement adds capital to its funding account, -1 when it takes capital out.
CREATE FUNCTION movement_sign(p_kind text) RETURNS int LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p_kind IN ('contribution','transfer_in') THEN 1 ELSE -1 END $$;

-- Capital that sets ownership share: contributions and transfers in, less withdrawals and transfers out,
-- counting only movements recorded before p_as_of (the moment the sale was recorded).
CREATE FUNCTION account_committed_capital(p_account uuid, p_as_of timestamptz DEFAULT 'infinity')
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(movement_sign(kind) * amount), 0) FROM capital_movements
   WHERE funding_account_id = p_account AND kind <> 'return_of_capital' AND created_at < p_as_of
$$;

-- Net cash a journal entry moves through cash accounts (debits - credits).
CREATE FUNCTION entry_cash_net(p_entry uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(jl.debit - jl.credit), 0)
    FROM journal_lines jl JOIN ledger_accounts a ON a.id = jl.ledger_account_id
   WHERE jl.journal_entry_id = p_entry AND a.is_cash
$$;

-- Part of an expense not yet allocated to an approved realization.
CREATE FUNCTION cost_unallocated(p_cost uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT c.amount - coalesce((SELECT sum(rc.amount) FROM realization_costs rc
                               JOIN profit_realizations r ON r.id = rc.realization_id
                              WHERE rc.deal_cost_id = c.id AND r.status = 'approved'), 0)
    FROM deal_costs c WHERE c.id = p_cost
$$;

-- Capital still held: every movement, less capital returned through approved distributions. Never negative.
CREATE FUNCTION account_net_capital(p_account uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT sum(movement_sign(kind) * amount) FROM capital_movements WHERE funding_account_id = p_account), 0)
       - coalesce((SELECT sum(l.capital_component) FROM distribution_lines l JOIN distribution_batches b ON b.id = l.batch_id
                    WHERE l.funding_account_id = p_account AND b.status IN ('approved','paid')), 0)
$$;

-- Portfolio cash: members' money in and out, money sent to / received back from deals,
-- deal payouts received and payouts made to members. Never negative.
CREATE FUNCTION portfolio_cash(p_portfolio uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT
    coalesce((SELECT sum(movement_sign(m.kind) * m.amount) FROM capital_movements m
               JOIN funding_accounts fa ON fa.id = m.funding_account_id
              WHERE fa.portfolio_id = p_portfolio), 0)
  - coalesce((SELECT sum(movement_sign(m.kind) * m.amount) FROM capital_movements m
               JOIN funding_accounts fa ON fa.id = m.funding_account_id
              WHERE fa.parent_portfolio_id = p_portfolio AND m.kind IN ('contribution','withdrawal','return_of_capital')), 0)
  + coalesce((SELECT sum(p.amount) FROM payouts p
               JOIN distribution_lines l ON l.id = p.distribution_line_id
               JOIN funding_accounts fa ON fa.id = l.funding_account_id
              WHERE l.beneficiary_type = 'portfolio' AND fa.parent_portfolio_id = p_portfolio), 0)
  - coalesce((SELECT sum(p.amount) FROM payouts p
               JOIN distribution_lines l ON l.id = p.distribution_line_id
               JOIN distribution_batches b ON b.id = l.batch_id
              WHERE b.portfolio_id = p_portfolio), 0)
$$;

-- Deal cash: capital in and out, sale proceeds, land purchase (price + tax + Dalalah), expenses and
-- payouts. Never negative.
CREATE FUNCTION deal_cash(p_deal uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT
    coalesce((SELECT sum(movement_sign(m.kind) * m.amount) FROM capital_movements m
               JOIN funding_accounts fa ON fa.id = m.funding_account_id WHERE fa.deal_id = p_deal), 0)
  + coalesce((SELECT sum(sale_amount) FROM deal_sales WHERE deal_id = p_deal AND status = 'completed'), 0)
  - coalesce((SELECT sum(total_cost) FROM land_purchases WHERE deal_id = p_deal), 0)
  - coalesce((SELECT sum(amount) FROM deal_costs WHERE deal_id = p_deal AND status = 'recorded'), 0)
  - coalesce((SELECT sum(p.amount) FROM payouts p
               JOIN distribution_lines l ON l.id = p.distribution_line_id
               JOIN distribution_batches b ON b.id = l.batch_id
              WHERE b.deal_id = p_deal), 0)
$$;

-- Serializes money movements per portfolio / deal: every writer locks the row first, so two
-- concurrent transactions cannot both spend the same cash. Lock order: portfolio, then deal.
CREATE FUNCTION lock_scope(p_type text, p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_id IS NULL THEN RETURN; END IF;
  IF p_type = 'deal' THEN
    PERFORM 1 FROM deals WHERE id = p_id FOR NO KEY UPDATE;
  ELSE
    PERFORM 1 FROM portfolios WHERE id = p_id FOR NO KEY UPDATE;
  END IF;
END $$;

CREATE FUNCTION assert_cash_not_negative(p_type text, p_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c numeric;
BEGIN
  IF p_id IS NULL THEN RETURN; END IF;
  IF p_type = 'deal' THEN
    c := deal_cash(p_id);
    IF c < 0 THEN RAISE EXCEPTION 'deal %: deal cash would be % (overspending)', p_id, c; END IF;
  ELSE
    c := portfolio_cash(p_id);
    IF c < 0 THEN RAISE EXCEPTION 'portfolio %: portfolio cash would be % (overspending)', p_id, c; END IF;
  END IF;
END $$;

CREATE FUNCTION assert_portfolio_open(p_portfolio uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_portfolio IS NOT NULL AND EXISTS (SELECT 1 FROM portfolios WHERE id = p_portfolio AND status = 'closed') THEN
    RAISE EXCEPTION 'portfolio % is closed', p_portfolio;
  END IF;
END $$;

CREATE FUNCTION assert_entry_posted(p_entry uuid, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = p_entry AND status = 'posted') THEN
    RAISE EXCEPTION '%: its journal entry must be posted', p_what;
  END IF;
END $$;

-- ===========================================================================
-- Rules that span rows, enforced by triggers
-- ===========================================================================

-- ---- Portfolios -----------------------------------------------------------
CREATE FUNCTION portfolios_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'closed' AND OLD.status <> 'closed'
     AND (portfolio_cash(OLD.id) <> 0
          OR EXISTS (SELECT 1 FROM funding_accounts WHERE parent_portfolio_id = OLD.id AND account_net_capital(id) > 0)) THEN
    RAISE EXCEPTION 'portfolio %: cannot close while it holds cash (%) or capital in deals', OLD.id, portfolio_cash(OLD.id);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER portfolios_before_write BEFORE UPDATE ON portfolios
  FOR EACH ROW EXECUTE FUNCTION portfolios_before_write();

-- ---- Lands ----------------------------------------------------------------
-- Recomputes a land's sale-driven status, then its parent's, up to the original land.
CREATE FUNCTION refresh_land_status(p_land_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  cur lands%ROWTYPE;
  new_status text;
  n_children int;
  n_sold int;
  n_touched int;
BEGIN
  SELECT * INTO cur FROM lands WHERE id = p_land_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT count(*),
         count(*) FILTER (WHERE status = 'sold'),
         count(*) FILTER (WHERE status IN ('sold','partially_sold'))
    INTO n_children, n_sold, n_touched
    FROM lands WHERE parent_land_id = p_land_id;

  IF EXISTS (SELECT 1 FROM deal_sales WHERE land_id = p_land_id AND status = 'completed') THEN
    new_status := 'sold';
  ELSIF n_children > 0 AND n_sold = n_children THEN
    new_status := 'sold';
  ELSIF n_touched > 0 THEN
    new_status := 'partially_sold';
  ELSIF cur.status IN ('sold','partially_sold') THEN
    new_status := 'available';           -- every sale under it was voided
  ELSE
    new_status := cur.status;
  END IF;

  IF new_status IS DISTINCT FROM cur.status THEN
    UPDATE lands SET status = new_status WHERE id = p_land_id;
  END IF;

  IF cur.parent_land_id IS NOT NULL THEN
    PERFORM refresh_land_status(cur.parent_land_id);
  END IF;
END $$;

CREATE FUNCTION lands_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  parent lands%ROWTYPE;
  resolved cities%ROWTYPE;
BEGIN
  -- Resolve the city from any accepted spelling (or from city_code alone); store its Arabic name.
  IF NEW.city IS NOT NULL THEN
    SELECT c.* INTO resolved FROM city_aliases a JOIN cities c ON c.code = a.city_code
     WHERE a.alias = lower(btrim(NEW.city));
    IF NOT FOUND THEN
      RAISE EXCEPTION 'unknown city "%": add it to cities and city_aliases', NEW.city;
    END IF;
  ELSIF NEW.city_code IS NOT NULL THEN
    SELECT * INTO resolved FROM cities WHERE code = NEW.city_code;
  END IF;
  IF resolved.code IS NOT NULL THEN
    NEW.city_code := resolved.code;
    NEW.city := resolved.name_ar;
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.parent_land_id IS DISTINCT FROM OLD.parent_land_id THEN
    RAISE EXCEPTION 'land %: parent_land_id cannot be changed after creation', OLD.id;
  END IF;

  IF ((TG_OP = 'INSERT' AND NEW.status IN ('sold','partially_sold'))
      OR (TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status
          AND (NEW.status IN ('sold','partially_sold') OR OLD.status IN ('sold','partially_sold'))))
     AND pg_trigger_depth() < 2 THEN
    -- Only the sale triggers (refresh_land_status, at trigger depth 2) may set these; no session setting
    -- or direct call from the application can.
    RAISE EXCEPTION 'land %: statuses sold and partially_sold are set automatically from recorded sales', NEW.id;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.parent_land_id IS NOT NULL THEN
    -- Lock the parent so a concurrent sale of it cannot slip past this check.
    SELECT * INTO parent FROM lands WHERE id = NEW.parent_land_id FOR UPDATE;
    IF FOUND THEN
      IF parent.status IN ('prospective','cancelled','sold') THEN
        RAISE EXCEPTION 'land %: cannot subdivide a land with status %', parent.id, parent.status;
      END IF;
      IF EXISTS (SELECT 1 FROM deal_sales WHERE land_id = parent.id AND status = 'completed') THEN
        RAISE EXCEPTION 'land %: cannot subdivide a land that has been sold', parent.id;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER lands_before_write BEFORE INSERT OR UPDATE ON lands
  FOR EACH ROW EXECUTE FUNCTION lands_before_write();

-- Parcels of one land never total more cost or area than the land itself.
CREATE FUNCTION check_parcel_totals(p_parent uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  p lands%ROWTYPE;
  cost_sum numeric;
  area_sum numeric;
BEGIN
  IF p_parent IS NULL THEN RETURN; END IF;
  SELECT * INTO p FROM lands WHERE id = p_parent;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT sum(purchase_price), sum(area_sqm) INTO cost_sum, area_sum FROM lands WHERE parent_land_id = p_parent;
  IF cost_sum IS NOT NULL AND (p.purchase_price IS NULL OR cost_sum > p.purchase_price) THEN
    RAISE EXCEPTION 'land %: parcel costs total % but the land''s cost is %',
      p.id, cost_sum, coalesce(p.purchase_price::text, 'not set');
  END IF;
  IF area_sum IS NOT NULL AND p.area_sqm IS NOT NULL AND area_sum > p.area_sqm THEN
    RAISE EXCEPTION 'land %: parcel areas total % m2 but the land is % m2', p.id, area_sum, p.area_sqm;
  END IF;
END $$;

CREATE FUNCTION lands_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM check_parcel_totals(NEW.parent_land_id);
  PERFORM check_parcel_totals(NEW.id);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER lands_check_deferred AFTER INSERT OR UPDATE ON lands
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION lands_check();

-- ---- Deals and office fee agreements ---------------------------------------
CREATE FUNCTION deals_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.land_id IS DISTINCT FROM OLD.land_id THEN
    RAISE EXCEPTION 'deal %: land_id cannot be changed', OLD.id;
  END IF;
  IF TG_OP = 'INSERT' AND EXISTS (SELECT 1 FROM lands WHERE id = NEW.land_id AND parent_land_id IS NOT NULL) THEN
    RAISE EXCEPTION 'deal must reference an original land, not a subdivided parcel (land %)', NEW.land_id;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.status = 'settled' AND OLD.status <> 'settled' AND (
       EXISTS (SELECT 1 FROM deal_sales s WHERE s.deal_id = NEW.id AND s.status = 'completed'
                AND NOT EXISTS (SELECT 1 FROM profit_realizations r WHERE r.deal_sale_id = s.id AND r.status = 'approved'))
    OR EXISTS (SELECT 1 FROM deal_costs c WHERE c.deal_id = NEW.id AND c.status = 'recorded'
                AND cost_unallocated(c.id) > 0)) THEN
    RAISE EXCEPTION 'deal %: every sale and expense must be in an approved profit realization before settling (use a closing realization for leftover expenses)', NEW.id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER deals_before_write BEFORE INSERT OR UPDATE ON deals
  FOR EACH ROW EXECUTE FUNCTION deals_before_write();

-- ---- Land purchases --------------------------------------------------------
CREATE FUNCTION land_purchases_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  d deals%ROWTYPE;
  l lands%ROWTYPE;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'land purchase %: recorded purchases cannot be changed or deleted', OLD.id;
  END IF;
  SELECT * INTO d FROM deals WHERE id = NEW.deal_id;
  SELECT * INTO l FROM lands WHERE id = NEW.land_id;
  IF NOT FOUND OR d.id IS NULL THEN RETURN NEW; END IF;   -- foreign keys report it
  IF d.land_id <> NEW.land_id THEN
    RAISE EXCEPTION 'land purchase: land % is not the land of deal %', NEW.land_id, d.id;
  END IF;
  IF l.status IN ('prospective','cancelled') THEN
    RAISE EXCEPTION 'land %: record the land as acquired before recording its purchase', l.id;
  END IF;
  IF l.purchase_price IS DISTINCT FROM NEW.amount THEN
    RAISE EXCEPTION 'land purchase: amount % must equal the land''s purchase_price %', NEW.amount, l.purchase_price;
  END IF;
  PERFORM lock_scope('deal', NEW.deal_id);
  RETURN NEW;
END $$;

CREATE TRIGGER land_purchases_before_write BEFORE INSERT OR UPDATE OR DELETE ON land_purchases
  FOR EACH ROW EXECUTE FUNCTION land_purchases_before_write();

-- The purchase journal entry pays out exactly price + purchase tax + Dalalah (no more, no less).
CREATE FUNCTION land_purchases_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  p land_purchases%ROWTYPE;
  cash_paid numeric;
BEGIN
  SELECT * INTO p FROM land_purchases WHERE id = NEW.id;
  PERFORM assert_entry_posted(p.journal_entry_id, format('land purchase %s', p.id));
  SELECT coalesce(sum(jl.credit), 0) - coalesce(sum(jl.debit), 0) INTO cash_paid
    FROM journal_lines jl JOIN ledger_accounts a ON a.id = jl.ledger_account_id
   WHERE jl.journal_entry_id = p.journal_entry_id AND a.is_cash;
  IF cash_paid <> p.total_cost THEN
    RAISE EXCEPTION 'land purchase %: cash paid % must equal price % + purchase tax % + Dalalah % = %',
      p.id, cash_paid, p.amount, p.purchase_tax, p.dalalah, p.total_cost;
  END IF;
  PERFORM assert_cash_not_negative('deal', p.deal_id);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER land_purchases_check_deferred AFTER INSERT ON land_purchases
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION land_purchases_check();

-- ---- Deal costs -----------------------------------------------------------
CREATE FUNCTION deal_costs_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'deal cost %: costs cannot be deleted; reverse the journal entry and void the cost', OLD.id;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'recorded' THEN
      RAISE EXCEPTION 'a new deal cost must be recorded, not voided';
    END IF;
    PERFORM lock_scope('deal', NEW.deal_id);
    IF EXISTS (SELECT 1 FROM deals WHERE id = NEW.deal_id AND status = 'settled') THEN
      RAISE EXCEPTION 'deal %: is settled; no further expenses can be recorded', NEW.deal_id;
    END IF;
    IF NEW.land_id IS NULL THEN
      SELECT land_id INTO NEW.land_id FROM deals WHERE id = NEW.deal_id;
    END IF;
    IF NOT EXISTS (
      WITH RECURSIVE up AS (
        SELECT id, parent_land_id FROM lands WHERE id = NEW.land_id
        UNION ALL
        SELECT p.id, p.parent_land_id FROM lands p JOIN up ON p.id = up.parent_land_id
      )
      SELECT 1 FROM up JOIN deals d ON d.land_id = up.id WHERE d.id = NEW.deal_id
    ) THEN
      RAISE EXCEPTION 'deal cost: land % is not the land of deal % or one of its parcels', NEW.land_id, NEW.deal_id;
    END IF;
    RETURN NEW;
  END IF;

  IF (NEW.deal_id, NEW.land_id, NEW.category, NEW.amount, NEW.incurred_on, NEW.journal_entry_id)
     IS DISTINCT FROM (OLD.deal_id, OLD.land_id, OLD.category, OLD.amount, OLD.incurred_on, OLD.journal_entry_id) THEN
    RAISE EXCEPTION 'deal cost %: recorded costs cannot be changed; void it and record a new cost', OLD.id;
  END IF;
  IF OLD.status = 'voided' AND NEW.status <> 'voided' THEN
    RAISE EXCEPTION 'deal cost %: a voided cost cannot be restored', OLD.id;
  END IF;
  IF OLD.status = 'recorded' AND NEW.status = 'voided' THEN
    IF EXISTS (SELECT 1 FROM realization_costs WHERE deal_cost_id = OLD.id) THEN
      RAISE EXCEPTION 'deal cost %: it has been allocated to a profit realization and cannot be voided', OLD.id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = OLD.journal_entry_id AND status = 'reversed') THEN
      RAISE EXCEPTION 'deal cost %: reverse its journal entry before voiding the cost', OLD.id;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER deal_costs_before_write BEFORE INSERT OR UPDATE OR DELETE ON deal_costs
  FOR EACH ROW EXECUTE FUNCTION deal_costs_before_write();

CREATE FUNCTION deal_costs_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c deal_costs%ROWTYPE;
BEGIN
  SELECT * INTO c FROM deal_costs WHERE id = NEW.id;
  IF c.status = 'recorded' THEN
    PERFORM assert_entry_posted(c.journal_entry_id, format('deal cost %s', c.id));
    IF entry_cash_net(c.journal_entry_id) <> -c.amount THEN
      RAISE EXCEPTION 'deal cost %: its journal entry pays % in cash but the cost is %',
        c.id, -entry_cash_net(c.journal_entry_id), c.amount;
    END IF;
    PERFORM assert_cash_not_negative('deal', c.deal_id);
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER deal_costs_check_deferred AFTER INSERT OR UPDATE ON deal_costs
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION deal_costs_check();

-- ---- Sales ----------------------------------------------------------------
CREATE FUNCTION deal_sales_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  l lands%ROWTYPE;
  d deals%ROWTYPE;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.deal_id, NEW.land_id, NEW.sale_amount, NEW.sold_on, NEW.buyer_name, NEW.payment_reference, NEW.journal_entry_id, NEW.recorded_at)
       IS DISTINCT FROM
       (OLD.deal_id, OLD.land_id, OLD.sale_amount, OLD.sold_on, OLD.buyer_name, OLD.payment_reference, OLD.journal_entry_id, OLD.recorded_at) THEN
      RAISE EXCEPTION 'deal sale %: a recorded sale cannot be edited; void it and record a new sale', OLD.id;
    END IF;
    IF OLD.status = 'voided' AND NEW.status <> 'voided' THEN
      RAISE EXCEPTION 'deal sale %: a voided sale cannot be restored', OLD.id;
    END IF;
    IF OLD.status = 'completed' AND NEW.status = 'voided' THEN
      IF EXISTS (SELECT 1 FROM profit_realizations WHERE deal_sale_id = OLD.id) THEN
        RAISE EXCEPTION 'deal sale %: it is included in a profit realization and cannot be voided', OLD.id;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = OLD.journal_entry_id AND status = 'reversed') THEN
        RAISE EXCEPTION 'deal sale %: reverse its journal entry before voiding the sale', OLD.id;
      END IF;
      PERFORM lock_scope('deal', OLD.deal_id);
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status <> 'completed' THEN
    RAISE EXCEPTION 'a new sale must be recorded as completed';
  END IF;

  PERFORM lock_scope('deal', NEW.deal_id);
  NEW.recorded_at := clock_timestamp();          -- never backdated: ownership is measured at this moment
  -- Lock the land so a concurrent subdivision or sale of it waits for this one.
  SELECT * INTO l FROM lands WHERE id = NEW.land_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;          -- foreign key reports it
  SELECT * INTO d FROM deals WHERE id = NEW.deal_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF d.status NOT IN ('active','sold') THEN
    RAISE EXCEPTION 'deal %: cannot record a sale while the deal is %', d.id, d.status;
  END IF;
  IF l.status IN ('prospective','cancelled') THEN
    RAISE EXCEPTION 'land %: cannot sell a land with status %', l.id, l.status;
  END IF;
  IF EXISTS (SELECT 1 FROM lands WHERE parent_land_id = l.id) THEN
    RAISE EXCEPTION 'land %: has been subdivided; sell its parcels instead', l.id;
  END IF;
  IF NOT EXISTS (
    WITH RECURSIVE up AS (
      SELECT id, parent_land_id FROM lands WHERE id = l.id
      UNION ALL
      SELECT p.id, p.parent_land_id FROM lands p JOIN up ON p.id = up.parent_land_id
    )
    SELECT 1 FROM up WHERE id = d.land_id
  ) THEN
    RAISE EXCEPTION 'land % is not the land of deal % or one of its parcels', l.id, d.id;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER deal_sales_before_write BEFORE INSERT OR UPDATE ON deal_sales
  FOR EACH ROW EXECUTE FUNCTION deal_sales_before_write();

CREATE FUNCTION deal_sales_after_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM refresh_land_status(NEW.land_id);
  RETURN NULL;
END $$;

CREATE TRIGGER deal_sales_after_write AFTER INSERT OR UPDATE ON deal_sales
  FOR EACH ROW EXECUTE FUNCTION deal_sales_after_write();

-- Full payment, and deal cash after a void: checked at commit, so the sale and its journal entry
-- can be written in either order.
CREATE FUNCTION deal_sales_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  s deal_sales%ROWTYPE;
  je_status text;
  cash numeric;
BEGIN
  SELECT * INTO s FROM deal_sales WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF s.status <> 'completed' THEN
    PERFORM assert_cash_not_negative('deal', s.deal_id);
    RETURN NULL;
  END IF;

  SELECT status INTO je_status FROM journal_entries WHERE id = s.journal_entry_id;
  IF je_status IS DISTINCT FROM 'posted' THEN
    RAISE EXCEPTION 'deal sale %: its journal entry must be posted when the sale is recorded (sales are paid in full)', s.id;
  END IF;

  SELECT coalesce(sum(jl.debit), 0) INTO cash
    FROM journal_lines jl JOIN ledger_accounts a ON a.id = jl.ledger_account_id
   WHERE jl.journal_entry_id = s.journal_entry_id AND a.is_cash;
  IF cash <> s.sale_amount THEN
    RAISE EXCEPTION 'deal sale %: cash received % must equal the sale amount % (no instalments)', s.id, cash, s.sale_amount;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER deal_sales_check_deferred AFTER INSERT OR UPDATE ON deal_sales
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION deal_sales_check();

-- ---- Profit realizations --------------------------------------------------
-- Acquisition cost of a land or parcel: the original land's purchase price + purchase tax + Dalalah,
-- allocated to a parcel in proportion to its allocated purchase price (rounded to the halala).
CREATE FUNCTION land_acquisition_cost(p_land uuid) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  missing uuid;
  root_id uuid;
  root_price numeric;
  land_price numeric;
  total numeric;
BEGIN
  WITH RECURSIVE up AS (
    SELECT id, parent_land_id, purchase_price, 0 AS depth FROM lands WHERE id = p_land
    UNION ALL
    SELECT p.id, p.parent_land_id, p.purchase_price, up.depth + 1 FROM lands p JOIN up ON p.id = up.parent_land_id
  )
  SELECT (SELECT id FROM up WHERE purchase_price IS NULL ORDER BY depth LIMIT 1),
         (SELECT id FROM up WHERE parent_land_id IS NULL),
         (SELECT purchase_price FROM up WHERE parent_land_id IS NULL),
         (SELECT purchase_price FROM up WHERE depth = 0)
    INTO missing, root_id, root_price, land_price;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'land %: set its allocated purchase price before approving profit on a sale', missing;
  END IF;
  SELECT total_cost INTO total FROM land_purchases WHERE land_id = root_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'land %: record the land purchase (with purchase tax and Dalalah) before approving profit', root_id;
  END IF;
  IF root_id = p_land THEN
    RETURN total;
  END IF;
  RETURN round(total * land_price / root_price, 2);
END $$;

CREATE FUNCTION profit_realizations_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  s deal_sales%ROWTYPE;
  sold_price numeric;
  c record;
  v_share numeric;
  acq numeric := 0;
  exp numeric := 0;
  before_fee numeric;
  root_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'profit realization %: an approved realization cannot be deleted', OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'profit realizations must be created as draft';
    END IF;
    IF EXISTS (SELECT 1 FROM deal_sales WHERE id = NEW.deal_sale_id AND status <> 'completed') THEN
      RAISE EXCEPTION 'deal sale %: profit can only be realized on a completed sale', NEW.deal_sale_id;
    END IF;
  ELSIF OLD.status = 'approved' THEN
    RAISE EXCEPTION 'profit realization %: an approved realization cannot be changed', OLD.id;
  ELSIF (NEW.deal_id, NEW.kind, NEW.deal_sale_id) IS DISTINCT FROM (OLD.deal_id, OLD.kind, OLD.deal_sale_id) THEN
    RAISE EXCEPTION 'profit realization %: deal, kind and sale cannot be changed', OLD.id;
  END IF;

  IF NEW.status = 'draft' THEN
    -- Figures are only ever computed by approval.
    NEW.sale_proceeds := NULL; NEW.acquisition_cost := NULL; NEW.expenses := NULL; NEW.office_fee := NULL;
    RETURN NEW;
  END IF;

  -- draft -> approved: allocate expenses, then compute and freeze the figures. Locking the deal
  -- serializes approvals so an expense is never allocated twice.
  PERFORM lock_scope('deal', NEW.deal_id);

  IF NEW.kind = 'sale' THEN
    SELECT * INTO s FROM deal_sales WHERE id = NEW.deal_sale_id;
    IF s.status <> 'completed' THEN
      RAISE EXCEPTION 'profit realization %: its sale has been voided', NEW.id;
    END IF;
    acq := land_acquisition_cost(s.land_id);
    SELECT purchase_price INTO sold_price FROM lands WHERE id = s.land_id;

    -- Expenses on the sold land itself are allocated in full; expenses on a land it was subdivided from
    -- are allocated in proportion to the sold land's share of that land's purchase price.
    FOR c IN
      WITH RECURSIVE up AS (
        SELECT id, parent_land_id, purchase_price FROM lands WHERE id = s.land_id
        UNION ALL
        SELECT p.id, p.parent_land_id, p.purchase_price FROM lands p JOIN up ON p.id = up.parent_land_id
      )
      SELECT dc.id, dc.amount, up.id AS cost_land, up.purchase_price AS cost_land_price
        FROM deal_costs dc JOIN up ON up.id = dc.land_id
       WHERE dc.deal_id = NEW.deal_id AND dc.status = 'recorded'
       ORDER BY dc.id
    LOOP
      v_share := least(cost_unallocated(c.id),
                       CASE WHEN c.cost_land = s.land_id THEN c.amount
                            ELSE round(c.amount * sold_price / c.cost_land_price, 2) END);
      IF v_share > 0 THEN
        INSERT INTO realization_costs (realization_id, deal_id, deal_cost_id, amount) VALUES (NEW.id, NEW.deal_id, c.id, v_share);
        exp := exp + v_share;
      END IF;
    END LOOP;
    NEW.sale_proceeds := s.sale_amount;
  ELSE
    SELECT l.status INTO root_status FROM deals d JOIN lands l ON l.id = d.land_id WHERE d.id = NEW.deal_id;
    IF root_status IS DISTINCT FROM 'sold' THEN
      RAISE EXCEPTION 'profit realization %: a closing realization needs all of the deal''s land sold first', NEW.id;
    END IF;
    IF EXISTS (SELECT 1 FROM deal_sales ds WHERE ds.deal_id = NEW.deal_id AND ds.status = 'completed'
                AND NOT EXISTS (SELECT 1 FROM profit_realizations r WHERE r.deal_sale_id = ds.id AND r.status = 'approved')) THEN
      RAISE EXCEPTION 'profit realization %: approve the profit on every sale before closing', NEW.id;
    END IF;
    FOR c IN SELECT id FROM deal_costs WHERE deal_id = NEW.deal_id AND status = 'recorded' ORDER BY id LOOP
      v_share := cost_unallocated(c.id);
      IF v_share > 0 THEN
        INSERT INTO realization_costs (realization_id, deal_id, deal_cost_id, amount) VALUES (NEW.id, NEW.deal_id, c.id, v_share);
        exp := exp + v_share;
      END IF;
    END LOOP;
    NEW.sale_proceeds := 0;
  END IF;

  before_fee := NEW.sale_proceeds - acq - exp;
  NEW.acquisition_cost := acq;
  NEW.expenses := exp;
  NEW.office_fee := CASE WHEN before_fee > 0 THEN round(before_fee * 0.25, 2) ELSE 0 END;
  NEW.approved_at := coalesce(NEW.approved_at, now());
  RETURN NEW;
END $$;

CREATE TRIGGER profit_realizations_before_write BEFORE INSERT OR UPDATE OR DELETE ON profit_realizations
  FOR EACH ROW EXECUTE FUNCTION profit_realizations_before_write();

-- Expense allocations are written only by realization approval, i.e. from inside the profit_realizations
-- trigger (trigger depth 2), or removed by the cascade from a draft realization. Never directly.
CREATE FUNCTION realization_costs_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF pg_trigger_depth() < 2 THEN
    RAISE EXCEPTION 'expense allocations are made automatically when a profit realization is approved';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER realization_costs_before_write BEFORE INSERT OR UPDATE OR DELETE ON realization_costs
  FOR EACH ROW EXECUTE FUNCTION realization_costs_before_write();

-- ---- Journal --------------------------------------------------------------
CREATE FUNCTION journal_entries_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'journal entry %: only draft entries can be deleted', OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'reversed' THEN
      RAISE EXCEPTION 'a journal entry cannot be created as reversed';
    END IF;
    IF NEW.reverses_entry_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = NEW.reverses_entry_id AND status = 'posted') THEN
      RAISE EXCEPTION 'journal entry %: only a posted entry can be reversed', NEW.reverses_entry_id;
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'draft' THEN
    IF NEW.status = 'reversed' THEN
      RAISE EXCEPTION 'journal entry %: a draft entry cannot be marked reversed', OLD.id;
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'posted' AND NEW.status = 'reversed'
     AND (NEW.occurred_on, NEW.description, NEW.source_type, NEW.source_id, NEW.approved_by, NEW.posted_at, NEW.reverses_entry_id)
         IS NOT DISTINCT FROM
         (OLD.occurred_on, OLD.description, OLD.source_type, OLD.source_id, OLD.approved_by, OLD.posted_at, OLD.reverses_entry_id) THEN
    IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE reverses_entry_id = OLD.id AND status = 'posted') THEN
      RAISE EXCEPTION 'journal entry %: post a reversing entry before marking it reversed', OLD.id;
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'journal entry %: posted entries cannot be edited; reverse them instead', OLD.id;
END $$;

CREATE TRIGGER journal_entries_before_write BEFORE INSERT OR UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION journal_entries_before_write();

CREATE FUNCTION journal_lines_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  a ledger_accounts%ROWTYPE;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE')
     AND (SELECT status FROM journal_entries WHERE id = OLD.journal_entry_id) <> 'draft' THEN
    RAISE EXCEPTION 'journal entry %: lines can only be changed while the entry is a draft', OLD.journal_entry_id;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  IF (SELECT status FROM journal_entries WHERE id = NEW.journal_entry_id) <> 'draft' THEN
    RAISE EXCEPTION 'journal entry %: lines can only be changed while the entry is a draft', NEW.journal_entry_id;
  END IF;

  SELECT * INTO a FROM ledger_accounts WHERE id = NEW.ledger_account_id;
  IF FOUND THEN
    IF a.deal_id IS NOT NULL AND NEW.deal_id IS DISTINCT FROM a.deal_id THEN
      RAISE EXCEPTION 'journal line: deal must match ledger account % (%)', a.code, a.deal_id;
    END IF;
    IF a.portfolio_id IS NOT NULL AND NEW.portfolio_id IS DISTINCT FROM a.portfolio_id THEN
      RAISE EXCEPTION 'journal line: portfolio must match ledger account % (%)', a.code, a.portfolio_id;
    END IF;
    IF a.investor_id IS NOT NULL AND NEW.investor_id IS DISTINCT FROM a.investor_id THEN
      RAISE EXCEPTION 'journal line: investor must match ledger account % (%)', a.code, a.investor_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER journal_lines_before_write BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION journal_lines_before_write();

-- Balance, reversal and source-consistency checks, at commit.
CREATE FUNCTION journal_entries_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e journal_entries%ROWTYPE;
  n int;
  dr numeric;
  cr numeric;
BEGIN
  SELECT * INTO e FROM journal_entries WHERE id = NEW.id;
  IF NOT FOUND OR e.status = 'draft' THEN RETURN NULL; END IF;

  SELECT count(*), coalesce(sum(debit), 0), coalesce(sum(credit), 0) INTO n, dr, cr
    FROM journal_lines WHERE journal_entry_id = e.id;
  IF n < 2 OR dr <> cr THEN
    RAISE EXCEPTION 'journal entry %: a posted entry needs at least two lines and equal debits and credits (lines %, debits %, credits %)',
      e.id, n, dr, cr;
  END IF;

  IF e.reverses_entry_id IS NOT NULL AND EXISTS (
    SELECT 1
      FROM (SELECT ledger_account_id, sum(debit - credit) AS net FROM journal_lines
             WHERE journal_entry_id = e.id GROUP BY 1) r
      FULL JOIN (SELECT ledger_account_id, sum(debit - credit) AS net FROM journal_lines
                  WHERE journal_entry_id = e.reverses_entry_id GROUP BY 1) o USING (ledger_account_id)
     WHERE coalesce(r.net, 0) <> -coalesce(o.net, 0)
  ) THEN
    RAISE EXCEPTION 'journal entry %: a reversal must exactly offset entry % account by account', e.id, e.reverses_entry_id;
  END IF;

  IF e.status = 'reversed' THEN
    IF EXISTS (SELECT 1 FROM deal_sales WHERE journal_entry_id = e.id AND status = 'completed') THEN
      RAISE EXCEPTION 'journal entry %: void the deal sale it records in the same transaction', e.id;
    END IF;
    IF EXISTS (SELECT 1 FROM deal_costs WHERE journal_entry_id = e.id AND status = 'recorded') THEN
      RAISE EXCEPTION 'journal entry %: void the deal cost it records in the same transaction', e.id;
    END IF;
    IF EXISTS (SELECT 1 FROM capital_movements WHERE journal_entry_id = e.id)
       OR EXISTS (SELECT 1 FROM payouts WHERE journal_entry_id = e.id)
       OR EXISTS (SELECT 1 FROM land_purchases WHERE journal_entry_id = e.id) THEN
      RAISE EXCEPTION 'journal entry %: it backs a permanent capital movement, payout or land purchase; record a compensating movement instead', e.id;
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER journal_entries_check_deferred AFTER INSERT OR UPDATE ON journal_entries
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION journal_entries_check();

-- ---- Capital movements ----------------------------------------------------
CREATE FUNCTION check_transfer_group(p_group uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  n_in int; n_out int; amt_in numeric; amt_out numeric; n_accounts int;
BEGIN
  IF p_group IS NULL THEN RETURN; END IF;
  SELECT count(*) FILTER (WHERE kind = 'transfer_in'), count(*) FILTER (WHERE kind = 'transfer_out'),
         sum(amount) FILTER (WHERE kind = 'transfer_in'), sum(amount) FILTER (WHERE kind = 'transfer_out'),
         count(DISTINCT funding_account_id)
    INTO n_in, n_out, amt_in, amt_out, n_accounts
    FROM capital_movements WHERE transfer_group_id = p_group;
  IF n_in + n_out = 0 THEN RETURN; END IF;
  IF n_in <> 1 OR n_out <> 1 OR amt_in <> amt_out OR n_accounts <> 2 THEN
    RAISE EXCEPTION 'transfer %: needs exactly one transfer_out and one transfer_in of the same amount between two different funding accounts', p_group;
  END IF;
END $$;

CREATE FUNCTION capital_movements_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  fa funding_accounts%ROWTYPE;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'capital movement %: recorded movements cannot be changed or deleted; record a compensating movement instead', OLD.id;
  END IF;
  NEW.created_at := clock_timestamp();           -- never backdated: ownership shares depend on it
  SELECT * INTO fa FROM funding_accounts WHERE id = NEW.funding_account_id;
  IF NOT FOUND THEN RETURN NEW; END IF;          -- foreign key reports it
  PERFORM lock_scope('portfolio', coalesce(fa.portfolio_id, fa.parent_portfolio_id));
  PERFORM lock_scope('deal', fa.deal_id);
  PERFORM assert_portfolio_open(coalesce(fa.portfolio_id, fa.parent_portfolio_id));
  RETURN NEW;
END $$;

CREATE TRIGGER capital_movements_before_write BEFORE INSERT OR UPDATE OR DELETE ON capital_movements
  FOR EACH ROW EXECUTE FUNCTION capital_movements_before_write();

CREATE FUNCTION capital_movements_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  fa funding_accounts%ROWTYPE;
  bal numeric;
BEGIN
  PERFORM check_transfer_group(NEW.transfer_group_id);
  PERFORM assert_entry_posted(NEW.journal_entry_id, format('capital movement %s', NEW.id));
  IF NEW.kind IN ('transfer_in','transfer_out') THEN
    IF (SELECT sum(debit) FROM journal_lines WHERE journal_entry_id = NEW.journal_entry_id) <> NEW.amount THEN
      RAISE EXCEPTION 'capital movement %: its journal entry totals % but the transfer is %',
        NEW.id, (SELECT sum(debit) FROM journal_lines WHERE journal_entry_id = NEW.journal_entry_id), NEW.amount;
    END IF;
  ELSIF entry_cash_net(NEW.journal_entry_id) <> movement_sign(NEW.kind) * NEW.amount THEN
    RAISE EXCEPTION 'capital movement %: its journal entry moves % in cash but the % is %',
      NEW.id, entry_cash_net(NEW.journal_entry_id), NEW.kind, NEW.amount;
  END IF;
  SELECT * INTO fa FROM funding_accounts WHERE id = NEW.funding_account_id;
  bal := account_net_capital(fa.id);
  IF bal < 0 THEN
    RAISE EXCEPTION 'funding account %: net capital would be % (cannot withdraw, transfer or return more than it holds)', fa.id, bal;
  END IF;
  PERFORM assert_cash_not_negative(fa.scope_type, fa.scope_id);
  PERFORM assert_cash_not_negative('portfolio', fa.parent_portfolio_id);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER capital_movements_check_deferred AFTER INSERT ON capital_movements
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION capital_movements_check();

-- ---- Distributions --------------------------------------------------------
CREATE FUNCTION distribution_batches_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'distribution batches must be created as draft';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'draft' THEN RETURN NEW; END IF;

  IF (NEW.deal_id, NEW.portfolio_id, NEW.amount, NEW.profit_realization_id, NEW.source_line_id, NEW.approved_at, NEW.journal_entry_id)
     IS DISTINCT FROM
     (OLD.deal_id, OLD.portfolio_id, OLD.amount, OLD.profit_realization_id, OLD.source_line_id, OLD.approved_at, OLD.journal_entry_id) THEN
    RAISE EXCEPTION 'distribution batch %: an approved batch cannot be edited', OLD.id;
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF NOT (OLD.status = 'approved' AND NEW.status IN ('paid','cancelled')) THEN
    RAISE EXCEPTION 'distribution batch %: cannot change status from % to %', OLD.id, OLD.status, NEW.status;
  END IF;
  IF NEW.status = 'cancelled' THEN
    IF EXISTS (SELECT 1 FROM payouts p JOIN distribution_lines l ON l.id = p.distribution_line_id WHERE l.batch_id = OLD.id) THEN
      RAISE EXCEPTION 'distribution batch %: cannot cancel a batch that has payouts', OLD.id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = OLD.journal_entry_id AND status = 'reversed') THEN
      RAISE EXCEPTION 'distribution batch %: reverse its approval journal entry before cancelling', OLD.id;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER distribution_batches_before_write BEFORE INSERT OR UPDATE ON distribution_batches
  FOR EACH ROW EXECUTE FUNCTION distribution_batches_before_write();

CREATE FUNCTION distribution_batches_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b distribution_batches%ROWTYPE;
  r profit_realizations%ROWTYPE;
  src distribution_lines%ROWTYPE;
  bad record;
  lines_total numeric;
  profit_sum numeric;
  capital_sum numeric;
  office_sum numeric;
  src_batch_status text;
  src_portfolio uuid;
  passed_on numeric;
  v_as_of timestamptz;
BEGIN
  SELECT * INTO b FROM distribution_batches WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  -- Ownership is measured at the moment the underlying sale was recorded.
  IF b.deal_id IS NOT NULL THEN
    SELECT s.recorded_at INTO v_as_of
      FROM profit_realizations pr JOIN deal_sales s ON s.id = pr.deal_sale_id
     WHERE pr.id = b.profit_realization_id;
  ELSE
    SELECT s.recorded_at INTO v_as_of
      FROM distribution_lines l
      JOIN distribution_batches x ON x.id = l.batch_id
      JOIN profit_realizations pr ON pr.id = x.profit_realization_id
      JOIN deal_sales s ON s.id = pr.deal_sale_id
     WHERE l.id = b.source_line_id;
  END IF;
  v_as_of := coalesce(v_as_of, 'infinity');

  IF b.status IN ('approved','paid') THEN
    SELECT coalesce(sum(amount), 0) INTO lines_total FROM distribution_lines WHERE batch_id = b.id;
    IF lines_total <> b.amount THEN
      RAISE EXCEPTION 'distribution batch %: lines total % does not equal batch amount %', b.id, lines_total, b.amount;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = b.journal_entry_id AND status = 'posted') THEN
      RAISE EXCEPTION 'distribution batch %: its approval journal entry must be posted', b.id;
    END IF;
    IF b.deal_id IS NOT NULL THEN
      SELECT * INTO r FROM profit_realizations WHERE id = b.profit_realization_id;
      IF r.status <> 'approved' THEN
        RAISE EXCEPTION 'distribution batch %: its profit realization must be approved first', b.id;
      END IF;
    END IF;

    -- No funding account may get back more capital than it holds.
    SELECT l.funding_account_id AS account, account_net_capital(l.funding_account_id) AS balance INTO bad
      FROM distribution_lines l
     WHERE l.batch_id = b.id AND l.funding_account_id IS NOT NULL AND account_net_capital(l.funding_account_id) < 0
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'distribution batch %: returns more capital than funding account % holds (balance would be %)',
        b.id, bad.account, bad.balance;
    END IF;

    -- Profit is split by ownership share (committed capital when the sale was recorded) among every holder
    -- in the batch's deal or portfolio, to the halala (0.01 rounding tolerance per holder).
    WITH holders AS (
      SELECT fa.id, account_committed_capital(fa.id, v_as_of) AS committed
        FROM funding_accounts fa WHERE fa.scope_type = b.scope_type AND fa.scope_id = b.scope_id
    ), got AS (
      SELECT funding_account_id AS id, sum(profit_component) AS profit
        FROM distribution_lines WHERE batch_id = b.id AND beneficiary_type <> 'office' GROUP BY 1
    ), total AS (
      SELECT sum(committed) FILTER (WHERE committed > 0) AS committed FROM holders
    ), batch_profit AS (
      SELECT coalesce(sum(profit), 0) AS profit FROM got
    )
    SELECT id AS account, coalesce(got.profit, 0) AS got,
           CASE WHEN total.committed > 0 AND coalesce(holders.committed, 0) > 0
                THEN round(batch_profit.profit * holders.committed / total.committed, 2) ELSE 0 END AS expected
      INTO bad
      FROM holders FULL JOIN got USING (id) CROSS JOIN total CROSS JOIN batch_profit
     WHERE abs(coalesce(got.profit, 0)
               - CASE WHEN total.committed > 0 AND coalesce(holders.committed, 0) > 0
                      THEN round(batch_profit.profit * holders.committed / total.committed, 2) ELSE 0 END) > 0.01
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'distribution batch %: profit must be split by ownership share (funding account %: expected %, got %)',
        b.id, bad.account, bad.expected, bad.got;
    END IF;

    -- A deal's distributions never exceed what its approved realization allows.
    IF b.deal_id IS NOT NULL THEN
      SELECT coalesce(sum(l.profit_component), 0), coalesce(sum(l.capital_component), 0),
             coalesce(sum(l.amount) FILTER (WHERE l.beneficiary_type = 'office'), 0)
        INTO profit_sum, capital_sum, office_sum
        FROM distribution_lines l JOIN distribution_batches x ON x.id = l.batch_id
       WHERE x.profit_realization_id = r.id AND x.status IN ('approved','paid');
      IF profit_sum > r.distributable_profit THEN
        RAISE EXCEPTION 'distribution batch %: profit distributed % exceeds distributable profit % of realization %',
          b.id, profit_sum, r.distributable_profit, r.id;
      END IF;
      IF capital_sum > r.returnable_capital THEN
        RAISE EXCEPTION 'distribution batch %: capital returned % exceeds returnable capital % of realization %',
          b.id, capital_sum, r.returnable_capital, r.id;
      END IF;
      IF office_sum > r.office_fee THEN
        RAISE EXCEPTION 'distribution batch %: office fee paid % exceeds the office fee % of realization %',
          b.id, office_sum, r.office_fee, r.id;
      END IF;
    END IF;
  END IF;

  IF b.status = 'paid' AND EXISTS (
    SELECT 1 FROM distribution_lines l
     WHERE l.batch_id = b.id
       AND l.amount <> (SELECT coalesce(sum(p.amount), 0) FROM payouts p WHERE p.distribution_line_id = l.id)
  ) THEN
    RAISE EXCEPTION 'distribution batch %: every line must be fully paid before the batch is marked paid', b.id;
  END IF;

  -- A portfolio passes on no more than the deal paid it, in total and in profit and capital separately.
  IF b.source_line_id IS NOT NULL THEN
    SELECT * INTO src FROM distribution_lines WHERE id = b.source_line_id;
    SELECT status INTO src_batch_status FROM distribution_batches WHERE id = src.batch_id;
    SELECT parent_portfolio_id INTO src_portfolio FROM funding_accounts WHERE id = src.funding_account_id;
    IF src.beneficiary_type <> 'portfolio' OR src_portfolio IS DISTINCT FROM b.portfolio_id THEN
      RAISE EXCEPTION 'distribution batch %: source line must be a deal payout to portfolio %', b.id, b.portfolio_id;
    END IF;
    IF src_batch_status NOT IN ('approved','paid') THEN
      RAISE EXCEPTION 'distribution batch %: source line''s batch must be approved', b.id;
    END IF;
    SELECT coalesce(sum(amount), 0) INTO passed_on FROM distribution_batches
     WHERE source_line_id = src.id AND status <> 'cancelled';
    IF passed_on > src.amount THEN
      RAISE EXCEPTION 'distribution batch %: portfolio batches total % but the deal paid the portfolio only %', b.id, passed_on, src.amount;
    END IF;
    SELECT coalesce(sum(l.profit_component), 0), coalesce(sum(l.capital_component), 0) INTO profit_sum, capital_sum
      FROM distribution_lines l JOIN distribution_batches x ON x.id = l.batch_id
     WHERE x.source_line_id = src.id AND x.status IN ('approved','paid');
    IF profit_sum > src.profit_component OR capital_sum > src.capital_component THEN
      RAISE EXCEPTION 'distribution batch %: passes on profit % / capital % but the deal paid profit % / capital %',
        b.id, profit_sum, capital_sum, src.profit_component, src.capital_component;
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER distribution_batches_check_deferred AFTER INSERT OR UPDATE ON distribution_batches
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION distribution_batches_check();

CREATE FUNCTION distribution_lines_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b distribution_batches%ROWTYPE;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE')
     AND (SELECT status FROM distribution_batches WHERE id = OLD.batch_id) <> 'draft' THEN
    RAISE EXCEPTION 'distribution batch %: lines can only be changed while the batch is a draft', OLD.batch_id;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  SELECT * INTO b FROM distribution_batches WHERE id = NEW.batch_id;
  IF FOUND THEN
    IF b.status <> 'draft' THEN
      RAISE EXCEPTION 'distribution batch %: lines can only be changed while the batch is a draft', b.id;
    END IF;
    NEW.scope_type := coalesce(NEW.scope_type, b.scope_type);
    NEW.scope_id := coalesce(NEW.scope_id, b.scope_id);
  END IF;
  IF NEW.beneficiary_type = 'investor' AND NEW.investor_id IS NULL THEN
    SELECT investor_id INTO NEW.investor_id FROM funding_accounts WHERE id = NEW.funding_account_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER distribution_lines_before_write BEFORE INSERT OR UPDATE OR DELETE ON distribution_lines
  FOR EACH ROW EXECUTE FUNCTION distribution_lines_before_write();

CREATE FUNCTION payouts_before_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  l distribution_lines%ROWTYPE;
  b distribution_batches%ROWTYPE;
  receiving_portfolio uuid;
  already_paid numeric;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'payout %: payouts cannot be changed or deleted', OLD.id;
  END IF;
  SELECT * INTO l FROM distribution_lines WHERE id = NEW.distribution_line_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  SELECT * INTO b FROM distribution_batches WHERE id = l.batch_id;
  IF b.status <> 'approved' THEN
    RAISE EXCEPTION 'payout: batch % is %; payouts are only made against an approved batch', b.id, b.status;
  END IF;

  IF l.beneficiary_type = 'portfolio' THEN
    SELECT parent_portfolio_id INTO receiving_portfolio FROM funding_accounts WHERE id = l.funding_account_id;
    PERFORM lock_scope('portfolio', receiving_portfolio);
    PERFORM assert_portfolio_open(receiving_portfolio);
  END IF;
  PERFORM lock_scope(b.scope_type, b.scope_id);
  PERFORM assert_portfolio_open(b.portfolio_id);

  SELECT coalesce(sum(amount), 0) INTO already_paid FROM payouts WHERE distribution_line_id = l.id;
  IF already_paid + NEW.amount > l.amount THEN
    RAISE EXCEPTION 'payout: % would exceed the % owed on distribution line % (already paid %)',
      NEW.amount, l.amount, l.id, already_paid;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER payouts_before_write BEFORE INSERT OR UPDATE OR DELETE ON payouts
  FOR EACH ROW EXECUTE FUNCTION payouts_before_write();

CREATE FUNCTION payouts_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b distribution_batches%ROWTYPE;
BEGIN
  PERFORM assert_entry_posted(NEW.journal_entry_id, format('payout %s', NEW.id));
  IF entry_cash_net(NEW.journal_entry_id) <> -NEW.amount THEN
    RAISE EXCEPTION 'payout %: its journal entry pays % in cash but the payout is %',
      NEW.id, -entry_cash_net(NEW.journal_entry_id), NEW.amount;
  END IF;
  SELECT b2.* INTO b FROM distribution_batches b2 JOIN distribution_lines l ON l.batch_id = b2.id
   WHERE l.id = NEW.distribution_line_id;
  PERFORM assert_cash_not_negative(b.scope_type, b.scope_id);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER payouts_check_deferred AFTER INSERT ON payouts
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payouts_check();

-- ===========================================================================
-- Accountability: acting employee, role permissions, four-eyes rule, who/when stamps, audit trail
-- ===========================================================================

-- ---- Who did what, and when ------------------------------------------------
-- Columns for each business step. All are set by the database (erp_stamp); values sent by the
-- application are ignored. journal_entries.approved_by / posted_at record who posted the entry.
ALTER TABLE journal_entries
  ADD CONSTRAINT journal_entries_approved_by_fk FOREIGN KEY (approved_by) REFERENCES app_users(id),
  ADD COLUMN reversed_by uuid REFERENCES app_users(id),
  ADD COLUMN reversed_at timestamptz;
COMMENT ON COLUMN journal_entries.approved_by IS 'Employee who posted the entry (never its preparer). Set by the database.';
ALTER TABLE profit_realizations
  ADD CONSTRAINT profit_realizations_approved_by_fk FOREIGN KEY (approved_by) REFERENCES app_users(id);
ALTER TABLE distribution_batches
  ADD COLUMN approved_by uuid REFERENCES app_users(id),
  ADD COLUMN paid_by uuid REFERENCES app_users(id),
  ADD COLUMN paid_at timestamptz,
  ADD COLUMN cancelled_by uuid REFERENCES app_users(id),
  ADD COLUMN cancelled_at timestamptz;
ALTER TABLE deal_sales ADD COLUMN voided_by uuid REFERENCES app_users(id), ADD COLUMN voided_at timestamptz;
ALTER TABLE deal_costs ADD COLUMN voided_by uuid REFERENCES app_users(id), ADD COLUMN voided_at timestamptz;
ALTER TABLE deals ADD COLUMN settled_by uuid REFERENCES app_users(id), ADD COLUMN settled_at timestamptz;
ALTER TABLE portfolios ADD COLUMN closed_by uuid REFERENCES app_users(id), ADD COLUMN closed_at timestamptz;

-- ---- Sessions and the acting employee ------------------------------------------
-- The login service (role erp_auth) authenticates an employee and opens a session with
-- erp_open_session(employee, token): only the SHA-256 hash of the token is stored. The application then
-- starts every transaction with erp_act_as(token). The database verifies the token and records the
-- employee in acting_context, bound to this connection AND this transaction, in a table the application
-- can neither read nor write. Nothing the application sets in its own session (e.g. set_config) is used
-- to decide who is acting, and the identity never carries over into the next transaction.
-- ONE EMPLOYEE PER TRANSACTION: once an employee is acting, the transaction cannot switch to anyone else,
-- even with another valid session token. Together with the four-eyes rule this means a record can only
-- be posted or approved in a separate transaction, by a different employee, from the one that prepared it.
CREATE TABLE user_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  token_hash bytea NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CONSTRAINT user_sessions_expiry CHECK (expires_at > created_at)
);
CREATE INDEX user_sessions_user_idx ON user_sessions (user_id);
COMMENT ON TABLE user_sessions IS 'Login sessions. Stores only the SHA-256 hash of each session token; written by the login service.';

CREATE UNLOGGED TABLE acting_context (
  backend_pid integer PRIMARY KEY,
  xact_id bigint NOT NULL,
  user_id uuid NOT NULL,
  session_id uuid,
  set_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
COMMENT ON TABLE acting_context IS 'Verified acting employee per connection and transaction. Written only by erp_act_as; not accessible to the application.';

-- Opens a session for an active employee. Called by the login service after it has verified the password.
CREATE FUNCTION erp_open_session(p_user uuid, p_token text, p_valid_for interval DEFAULT interval '8 hours')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u app_users%ROWTYPE;
  sid uuid;
BEGIN
  IF p_token IS NULL OR length(p_token) < 32 THEN
    RAISE EXCEPTION 'session tokens must be at least 32 characters of random data';
  END IF;
  IF p_valid_for IS NULL OR p_valid_for <= interval '0' OR p_valid_for > interval '24 hours' THEN
    RAISE EXCEPTION 'session lifetime must be between 0 and 24 hours';
  END IF;
  SELECT * INTO u FROM app_users WHERE id = p_user;
  IF NOT FOUND OR u.is_system THEN
    RAISE EXCEPTION 'sessions can only be opened for employees (never the system user)';
  END IF;
  IF u.status <> 'active' THEN
    RAISE EXCEPTION 'employee % is disabled', u.full_name;
  END IF;
  INSERT INTO user_sessions (user_id, token_hash, expires_at)
  VALUES (u.id, digest(p_token, 'sha256'), now() + p_valid_for)
  RETURNING id INTO sid;
  RETURN sid;
END $$;

CREATE FUNCTION erp_revoke_session(p_session uuid) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS
$$ UPDATE user_sessions SET revoked_at = now() WHERE id = p_session AND revoked_at IS NULL $$;

-- Refuses a second, different employee in the same transaction.
CREATE FUNCTION erp_assert_no_switch(p_user uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE current_actor uuid;
BEGIN
  SELECT user_id INTO current_actor FROM acting_context
   WHERE backend_pid = pg_backend_pid() AND xact_id = txid_current();
  IF current_actor IS NOT NULL AND current_actor <> p_user THEN
    RAISE EXCEPTION 'one employee per transaction: % is already acting in this transaction; % must act in a separate transaction',
      (SELECT full_name FROM app_users WHERE id = current_actor), (SELECT full_name FROM app_users WHERE id = p_user)
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

CREATE FUNCTION erp_act_as(p_token text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  s user_sessions%ROWTYPE;
  u app_users%ROWTYPE;
BEGIN
  SELECT * INTO s FROM user_sessions WHERE token_hash = digest(coalesce(p_token, ''), 'sha256');
  IF NOT FOUND OR s.revoked_at IS NOT NULL OR s.expires_at <= now() THEN
    RAISE EXCEPTION 'invalid, expired or revoked session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO u FROM app_users WHERE id = s.user_id;
  IF u.status <> 'active' THEN
    RAISE EXCEPTION 'acting employee % (%) is disabled', u.full_name, u.id USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM erp_assert_no_switch(u.id);
  INSERT INTO acting_context (backend_pid, xact_id, user_id, session_id)
  VALUES (pg_backend_pid(), txid_current(), u.id, s.id)
  ON CONFLICT (backend_pid) DO UPDATE
     SET xact_id = EXCLUDED.xact_id, user_id = EXCLUDED.user_id, session_id = EXCLUDED.session_id,
         set_at = clock_timestamp();
END $$;
COMMENT ON FUNCTION erp_act_as(text) IS 'Verifies a session token and names its employee for the current transaction only (one employee per transaction). Required before any write.';

-- Logs out the session acting in the current transaction.
CREATE FUNCTION erp_end_session() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE user_sessions SET revoked_at = now()
   WHERE id = (SELECT session_id FROM acting_context
                WHERE backend_pid = pg_backend_pid() AND xact_id = txid_current())
     AND revoked_at IS NULL;
END $$;

-- Seeds and maintenance only (database owner): act as the built-in system user, which has Data Entry
-- rights and can never post or approve. Not callable by the application.
CREATE FUNCTION erp_act_as_system() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT erp_assert_no_switch(erp_system_user_id());
  INSERT INTO acting_context (backend_pid, xact_id, user_id, session_id)
  VALUES (pg_backend_pid(), txid_current(), erp_system_user_id(), NULL)
  ON CONFLICT (backend_pid) DO UPDATE
     SET xact_id = EXCLUDED.xact_id, user_id = EXCLUDED.user_id, session_id = NULL, set_at = clock_timestamp()
$$;

-- The acting employee for this transaction, or NULL. Never reads anything the application can set.
CREATE FUNCTION erp_acting_user_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT user_id FROM acting_context WHERE backend_pid = pg_backend_pid() AND xact_id = txid_current()
$$;

CREATE FUNCTION erp_acting_user() RETURNS app_users LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  uid uuid := erp_acting_user_id();
  u app_users%ROWTYPE;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'no acting employee: call erp_act_as(<session token>) at the start of the transaction'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO u FROM app_users WHERE id = uid;
  IF u.status <> 'active' THEN
    RAISE EXCEPTION 'acting employee % (%) is disabled', u.full_name, u.id USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN u;
END $$;

CREATE FUNCTION erp_require(p_roles text[], p_action text) RETURNS app_users LANGUAGE plpgsql STABLE AS $$
DECLARE u app_users%ROWTYPE := erp_acting_user();
BEGIN
  IF NOT (u.role = ANY (p_roles)) THEN
    RAISE EXCEPTION 'permission denied: % requires role %; % is %',
      p_action, array_to_string(p_roles, ' or '), u.full_name, u.role USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN u;
END $$;

-- Four-eyes rule: no exceptions for any role. The record simply stays pending until another
-- authorized employee acts.
CREATE FUNCTION erp_four_eyes(p_user app_users, p_preparers uuid[], p_action text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_user.id = ANY (p_preparers) THEN
    RAISE EXCEPTION 'four-eyes rule: % prepared this record and cannot % it; it stays pending until another authorized employee does',
      p_user.full_name, p_action USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

-- First admin, for a new installation only (run by the database owner; not callable by the application).
-- Runs with the owner's privileges; the permission check accepts it only for the owner and only while no
-- admin exists. No session setting is involved.
CREATE FUNCTION erp_bootstrap_admin(p_full_name text, p_email text, p_id uuid DEFAULT gen_random_uuid())
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM app_users WHERE role = 'admin' AND NOT is_system) THEN
    RAISE EXCEPTION 'an admin already exists; admins create further employees';
  END IF;
  PERFORM erp_act_as_system();
  INSERT INTO app_users (id, full_name, email, role) VALUES (p_id, p_full_name, p_email, 'admin');
  RETURN p_id;
END $$;

-- True only when running with the privileges of the schema owner (inside an owner-run function or an
-- owner session), never for the application roles.
CREATE FUNCTION erp_running_as_owner() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT (SELECT relowner FROM pg_class WHERE oid = 'app_users'::regclass)
         = (SELECT oid FROM pg_roles WHERE rolname = current_user)
$$;

-- ---- Soft deletion of master data ---------------------------------------------------
-- These tables are never deleted from; records are deactivated (is_active = false) and inactive records
-- cannot be used for new activity. History, accounting and audit references stay intact.
CREATE FUNCTION erp_soft_delete_tables() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['investors','portfolios','lands','deals','funding_accounts','ledger_accounts','documents',
               'cities','city_aliases']
$$;

CREATE FUNCTION erp_assert_active(p_table regclass, p_id anyelement, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_active boolean;
BEGIN
  IF p_id IS NULL THEN RETURN; END IF;
  EXECUTE format('SELECT is_active FROM %s WHERE %I = $1', p_table,
                 CASE WHEN p_table = 'city_aliases'::regclass THEN 'alias' ELSE 'id' END)
    INTO v_active USING p_id;
  IF v_active IS FALSE THEN
    RAISE EXCEPTION '% % is inactive and cannot be used for new records', p_what, p_id;
  END IF;
END $$;

-- ---- Permissions (checked before every other rule; fails closed for unknown tables) ----
CREATE FUNCTION erp_authorize() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  u app_users%ROWTYPE;
  editors   CONSTANT text[] := ARRAY['admin','accountant','data_entry'];
  finance   CONSTANT text[] := ARRAY['admin','accountant'];
  admins    CONSTANT text[] := ARRAY['admin'];
  preparers uuid[];
  step text;
BEGIN
  IF TG_OP = 'DELETE' AND TG_TABLE_NAME = ANY (erp_soft_delete_tables()) THEN
    RAISE EXCEPTION '% records are never deleted; deactivate them instead (set is_active = false)', TG_TABLE_NAME;
  END IF;

  CASE TG_TABLE_NAME
  WHEN 'realization_costs' THEN
    NULL;                                        -- written only by an approval, which is itself authorized
  WHEN 'app_users' THEN
    IF TG_OP = 'INSERT' AND NEW.role = 'admin' AND NOT NEW.is_system AND erp_running_as_owner()
       AND NOT EXISTS (SELECT 1 FROM app_users WHERE role = 'admin' AND NOT is_system) THEN
      RETURN NEW;                                -- first admin of a new installation (erp_bootstrap_admin)
    END IF;
    u := erp_require(admins, 'managing employees');
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'employees cannot be deleted; disable them instead';
    ELSIF TG_OP = 'INSERT' THEN
      IF NEW.is_system THEN
        RAISE EXCEPTION 'system users cannot be created';
      END IF;
    ELSE
      IF OLD.is_system OR NEW.is_system THEN
        RAISE EXCEPTION 'the system user cannot be changed';
      END IF;
      IF OLD.id = u.id AND (NEW.role, NEW.status) IS DISTINCT FROM (OLD.role, OLD.status) THEN
        RAISE EXCEPTION 'employees cannot change their own role or status';
      END IF;
    END IF;
  WHEN 'user_credentials' THEN
    u := erp_acting_user();
    IF TG_OP = 'DELETE' THEN
      IF u.role <> 'admin' THEN
        PERFORM erp_require(admins, 'removing login credentials');
      END IF;
    ELSE
      IF EXISTS (SELECT 1 FROM app_users WHERE id = NEW.user_id AND is_system) THEN
        RAISE EXCEPTION 'the system user can never have login credentials';
      END IF;
      IF NEW.user_id <> u.id AND u.role <> 'admin' THEN
        PERFORM erp_require(admins, 'setting another employee''s credentials');
      END IF;
    END IF;
  WHEN 'cities', 'city_aliases' THEN
    u := erp_require(admins, 'managing cities');
  WHEN 'investors', 'lands', 'funding_accounts', 'documents', 'journal_lines' THEN
    u := erp_require(editors, 'editing ' || TG_TABLE_NAME);
  WHEN 'portfolios' THEN
    IF TG_OP = 'UPDATE' THEN
      IF NEW.status = 'closed' AND OLD.status <> 'closed' THEN
        u := erp_require(admins, 'closing a portfolio');
        PERFORM erp_four_eyes(u, ARRAY[OLD.created_by], 'close');
        RETURN NEW;
      END IF;
    END IF;
    u := erp_require(editors, 'editing portfolios');
  WHEN 'deals' THEN
    IF TG_OP = 'UPDATE' THEN
      IF NEW.status = 'settled' AND OLD.status <> 'settled' THEN
        u := erp_require(admins, 'settling a deal');
        PERFORM erp_four_eyes(u, ARRAY[OLD.created_by], 'settle');
        RETURN NEW;
      END IF;
    END IF;
    u := erp_require(editors, 'editing deals');
  WHEN 'ledger_accounts', 'capital_movements', 'land_purchases', 'deal_costs', 'deal_sales', 'payouts',
       'distribution_lines' THEN
    u := erp_require(finance, 'recording ' || TG_TABLE_NAME);
  WHEN 'journal_entries' THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.status <> 'draft' THEN
        RAISE EXCEPTION 'journal entries must be created as draft and posted by a second employee';
      END IF;
      u := erp_require(editors, 'drafting journal entries');
    ELSIF TG_OP = 'UPDATE' AND OLD.status = 'draft' AND NEW.status = 'posted' THEN
      u := erp_require(finance, 'posting a journal entry');
      preparers := ARRAY[OLD.created_by]
                   || ARRAY(SELECT created_by FROM journal_lines WHERE journal_entry_id = OLD.id);
      PERFORM erp_four_eyes(u, preparers, 'post');
    ELSIF TG_OP = 'UPDATE' AND NEW.status = 'reversed' AND OLD.status <> 'reversed' THEN
      u := erp_require(finance, 'reversing a journal entry');
    ELSE
      u := erp_require(editors, 'editing draft journal entries');
    END IF;
  WHEN 'profit_realizations' THEN
    IF TG_OP = 'UPDATE' THEN
      IF NEW.status = 'approved' AND OLD.status <> 'approved' THEN
        u := erp_require(admins, 'approving a profit realization');
        PERFORM erp_four_eyes(u, ARRAY[OLD.created_by], 'approve');
        RETURN NEW;
      END IF;
    END IF;
    u := erp_require(finance, 'preparing profit realizations');
  WHEN 'distribution_batches' THEN
    IF TG_OP = 'UPDATE' THEN
      IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('approved','paid','cancelled') THEN
        step := CASE NEW.status WHEN 'approved' THEN 'approve' WHEN 'paid' THEN 'mark as paid' ELSE 'cancel' END;
        u := erp_require(admins, step || ' a distribution');
        preparers := ARRAY[OLD.created_by]
                     || ARRAY(SELECT created_by FROM distribution_lines WHERE batch_id = OLD.id);
        PERFORM erp_four_eyes(u, preparers, step);
        RETURN NEW;
      END IF;
    END IF;
    u := erp_require(finance, 'preparing distributions');
  ELSE
    RAISE EXCEPTION 'no permission rule defined for table %', TG_TABLE_NAME;
  END CASE;

  -- Inactive (soft-deleted) master data cannot be used for new records.
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'journal_lines') THEN
    CASE TG_TABLE_NAME
    WHEN 'funding_accounts' THEN
      PERFORM erp_assert_active('investors'::regclass, NEW.investor_id, 'investor');
      PERFORM erp_assert_active('portfolios'::regclass, NEW.portfolio_id, 'portfolio');
      PERFORM erp_assert_active('portfolios'::regclass, NEW.parent_portfolio_id, 'portfolio');
      PERFORM erp_assert_active('deals'::regclass, NEW.deal_id, 'deal');
    WHEN 'deals' THEN
      PERFORM erp_assert_active('lands'::regclass, NEW.land_id, 'land');
    WHEN 'lands' THEN
      PERFORM erp_assert_active('lands'::regclass, NEW.parent_land_id, 'parent land');
    WHEN 'journal_lines' THEN
      PERFORM erp_assert_active('ledger_accounts'::regclass, NEW.ledger_account_id, 'ledger account');
    WHEN 'capital_movements' THEN
      PERFORM erp_assert_active('funding_accounts'::regclass, NEW.funding_account_id, 'funding account');
    WHEN 'deal_sales', 'land_purchases', 'deal_costs' THEN
      PERFORM erp_assert_active('lands'::regclass, NEW.land_id, 'land');
    ELSE
      NULL;
    END CASE;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

-- ---- Who/when stamps --------------------------------------------------------
CREATE FUNCTION erp_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  uid uuid := (erp_acting_user()).id;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := uid;  NEW.created_at := now();
    NEW.updated_by := NULL; NEW.updated_at := NULL;
  ELSE
    NEW.created_by := OLD.created_by; NEW.created_at := OLD.created_at;
    NEW.updated_by := uid;            NEW.updated_at := now();
  END IF;

  CASE TG_TABLE_NAME
  WHEN 'journal_entries' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.approved_by := NULL; NEW.posted_at := NULL; NEW.reversed_by := NULL; NEW.reversed_at := NULL;
    ELSIF OLD.status = 'draft' AND NEW.status = 'posted' THEN
      NEW.approved_by := uid; NEW.posted_at := now();
    ELSIF OLD.status = 'draft' THEN
      NEW.approved_by := NULL; NEW.posted_at := NULL;
    ELSE
      NEW.approved_by := OLD.approved_by; NEW.posted_at := OLD.posted_at;
      IF OLD.status = 'posted' AND NEW.status = 'reversed' THEN
        NEW.reversed_by := uid; NEW.reversed_at := now();
      ELSE
        NEW.reversed_by := OLD.reversed_by; NEW.reversed_at := OLD.reversed_at;
      END IF;
    END IF;
  WHEN 'profit_realizations' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.approved_by := NULL; NEW.approved_at := NULL;
    ELSIF OLD.status = 'draft' AND NEW.status = 'approved' THEN
      NEW.approved_by := uid; NEW.approved_at := now();
    ELSE
      NEW.approved_by := OLD.approved_by; NEW.approved_at := OLD.approved_at;
    END IF;
  WHEN 'distribution_batches' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.approved_by := NULL; NEW.approved_at := NULL; NEW.paid_by := NULL; NEW.paid_at := NULL;
      NEW.cancelled_by := NULL; NEW.cancelled_at := NULL;
    ELSE
      IF OLD.status = 'draft' AND NEW.status = 'approved' THEN
        NEW.approved_by := uid; NEW.approved_at := now();
      ELSIF OLD.status <> 'draft' THEN
        NEW.approved_by := OLD.approved_by; NEW.approved_at := OLD.approved_at;
      END IF;
      IF NEW.status = 'paid' AND OLD.status <> 'paid' THEN
        NEW.paid_by := uid; NEW.paid_at := now();
      ELSE
        NEW.paid_by := OLD.paid_by; NEW.paid_at := OLD.paid_at;
      END IF;
      IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
        NEW.cancelled_by := uid; NEW.cancelled_at := now();
      ELSE
        NEW.cancelled_by := OLD.cancelled_by; NEW.cancelled_at := OLD.cancelled_at;
      END IF;
    END IF;
  WHEN 'deal_sales', 'deal_costs' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.voided_by := NULL; NEW.voided_at := NULL;
    ELSIF NEW.status = 'voided' AND OLD.status <> 'voided' THEN
      NEW.voided_by := uid; NEW.voided_at := now();
    ELSE
      NEW.voided_by := OLD.voided_by; NEW.voided_at := OLD.voided_at;
    END IF;
  WHEN 'deals' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.settled_by := NULL; NEW.settled_at := NULL;
    ELSIF NEW.status = 'settled' AND OLD.status <> 'settled' THEN
      NEW.settled_by := uid; NEW.settled_at := now();
    ELSE
      NEW.settled_by := OLD.settled_by; NEW.settled_at := OLD.settled_at;
    END IF;
  WHEN 'portfolios' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.closed_by := NULL; NEW.closed_at := NULL;
    ELSIF NEW.status = 'closed' AND OLD.status <> 'closed' THEN
      NEW.closed_by := uid; NEW.closed_at := now();
    ELSE
      NEW.closed_by := OLD.closed_by; NEW.closed_at := OLD.closed_at;
    END IF;
  ELSE
    NULL;
  END CASE;

  IF TG_TABLE_NAME = ANY (erp_soft_delete_tables()) THEN
    IF TG_OP = 'INSERT' THEN
      NEW.deactivated_by := CASE WHEN NEW.is_active THEN NULL ELSE uid END;
      NEW.deactivated_at := CASE WHEN NEW.is_active THEN NULL ELSE now() END;
    ELSIF OLD.is_active AND NOT NEW.is_active THEN
      NEW.deactivated_by := uid; NEW.deactivated_at := now();
    ELSIF NEW.is_active THEN
      NEW.deactivated_by := NULL; NEW.deactivated_at := NULL;
    ELSE
      NEW.deactivated_by := OLD.deactivated_by; NEW.deactivated_at := OLD.deactivated_at;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---- Audit trail -------------------------------------------------------------
-- SECURITY DEFINER so the application role, which cannot write audit_events itself, still gets every
-- change recorded.
CREATE FUNCTION erp_audit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o jsonb;
  n jsonb;
  r jsonb;
  act text;
BEGIN
  IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN n := to_jsonb(NEW); END IF;
  IF TG_TABLE_NAME = 'user_credentials' THEN
    o := o - 'password_hash';
    n := n - 'password_hash';
  ELSIF TG_TABLE_NAME = 'user_sessions' THEN
    o := o - 'token_hash';
    n := n - 'token_hash';
  END IF;
  r := coalesce(n, o);

  act := CASE TG_OP WHEN 'INSERT' THEN 'create' WHEN 'DELETE' THEN 'delete' ELSE 'update' END;
  IF TG_OP = 'UPDATE' AND (o->>'status') IS DISTINCT FROM (n->>'status') THEN
    act := CASE n->>'status'
             WHEN 'posted' THEN 'post'     WHEN 'reversed' THEN 'reverse' WHEN 'approved' THEN 'approve'
             WHEN 'paid' THEN 'pay'        WHEN 'cancelled' THEN 'cancel' WHEN 'voided' THEN 'void'
             WHEN 'settled' THEN 'settle'  WHEN 'closed' THEN 'close'     WHEN 'disabled' THEN 'disable'
             ELSE 'status_change' END;
  END IF;
  IF TG_TABLE_NAME = 'app_users' AND TG_OP = 'UPDATE' AND (o->>'role') IS DISTINCT FROM (n->>'role') THEN
    act := 'role_change';
  END IF;
  IF TG_OP = 'UPDATE' AND (o->>'is_active') IS DISTINCT FROM (n->>'is_active') THEN
    act := CASE WHEN (n->>'is_active')::boolean THEN 'reactivate' ELSE 'deactivate' END;
  END IF;
  IF TG_TABLE_NAME = 'user_credentials' THEN
    act := 'credential_' || act;
  ELSIF TG_TABLE_NAME = 'user_sessions' THEN
    act := CASE WHEN TG_OP = 'INSERT' THEN 'session_open'
                WHEN (o->>'revoked_at') IS NULL AND (n->>'revoked_at') IS NOT NULL THEN 'session_revoke'
                ELSE 'session_' || act END;
  END IF;

  INSERT INTO audit_events (actor_id, entity_type, entity_id, action, old_values, new_values)
  VALUES (CASE WHEN TG_TABLE_NAME = 'user_sessions' THEN coalesce(erp_acting_user_id(), (r->>'user_id')::uuid)
               ELSE erp_acting_user_id() END,
          TG_TABLE_NAME,
          coalesce(r->>'id', r->>'user_id', r->>'alias', (r->>'realization_id') || ':' || (r->>'deal_cost_id')),
          act, o, n);
  RETURN NULL;
END $$;

CREATE FUNCTION audit_events_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only: audit records can never be changed or deleted';
END $$;
CREATE TRIGGER audit_events_append_only BEFORE UPDATE OR DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION audit_events_append_only();
CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION audit_events_append_only();

-- ---- Protect every table, now and in the future -------------------------------------------
-- erp_protect_table adds created_by/created_at/updated_by/updated_at and attaches the permission, stamp
-- and audit triggers. Trigger names sort first (aa_, ab_) so permissions and stamps apply before every
-- other rule; zz_audit runs last. Every new table in schema public is protected automatically by the
-- event trigger below, and is unwritable until a permission rule is added to erp_authorize (fails closed).
CREATE FUNCTION erp_protect_table(p_table regclass) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now()', p_table);
  EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS created_by uuid NOT NULL DEFAULT %L REFERENCES app_users(id)',
                 p_table, erp_system_user_id());
  EXECUTE format('ALTER TABLE %s ALTER COLUMN created_by DROP DEFAULT', p_table);
  EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES app_users(id), '
                 'ADD COLUMN IF NOT EXISTS updated_at timestamptz', p_table);
  EXECUTE format('CREATE OR REPLACE TRIGGER aa_authorize BEFORE INSERT OR UPDATE OR DELETE ON %s '
                 'FOR EACH ROW EXECUTE FUNCTION erp_authorize()', p_table);
  EXECUTE format('CREATE OR REPLACE TRIGGER ab_stamp BEFORE INSERT OR UPDATE ON %s '
                 'FOR EACH ROW EXECUTE FUNCTION erp_stamp()', p_table);
  EXECUTE format('CREATE OR REPLACE TRIGGER zz_audit AFTER INSERT OR UPDATE OR DELETE ON %s '
                 'FOR EACH ROW EXECUTE FUNCTION erp_audit()', p_table);
  EXECUTE format('REVOKE ALL ON %s FROM PUBLIC', p_table);
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY erp_soft_delete_tables() LOOP
    EXECUTE format('ALTER TABLE %I ADD COLUMN is_active boolean NOT NULL DEFAULT true, '
                   'ADD COLUMN deactivated_by uuid REFERENCES app_users(id), ADD COLUMN deactivated_at timestamptz', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY[
    'app_users','user_credentials','cities','city_aliases',
    'investors','portfolios','lands','deals','funding_accounts','ledger_accounts',
    'journal_entries','journal_lines','capital_movements','land_purchases','deal_costs','deal_sales',
    'profit_realizations','realization_costs','distribution_batches','distribution_lines','payouts','documents']
  LOOP
    PERFORM erp_protect_table(t::regclass);
  END LOOP;
END $$;

-- Sessions are opened before anyone is acting, so they get the audit trigger only.
CREATE TRIGGER zz_audit AFTER INSERT OR UPDATE OR DELETE ON user_sessions FOR EACH ROW EXECUTE FUNCTION erp_audit();

-- Tables that are deliberately not protected by erp_protect_table (checked by the test suite).
CREATE FUNCTION erp_unprotected_tables() RETURNS SETOF text LANGUAGE sql STABLE AS $$
  SELECT c.relname::text FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','p')
     AND c.relname NOT IN ('audit_events','acting_context','user_sessions')
     AND NOT (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname = 'aa_authorize')
              AND EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname = 'ab_stamp')
              AND EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname = 'zz_audit'))
$$;

CREATE FUNCTION erp_protect_new_tables() RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
              WHERE object_type = 'table' AND schema_name = 'public'
                AND command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  LOOP
    PERFORM erp_protect_table(obj.objid::regclass);
  END LOOP;
END $$;

-- Event triggers need superuser rights to install. Without them the schema still installs, with a
-- warning; erp_unprotected_tables() then shows any later table that was not protected by hand.
DO $$
BEGIN
  IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    CREATE EVENT TRIGGER erp_protect_new_tables ON ddl_command_end
      WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      EXECUTE FUNCTION erp_protect_new_tables();
  ELSE
    RAISE WARNING 'erp_protect_new_tables event trigger NOT installed (needs superuser): protect new tables with erp_protect_table()';
  END IF;
END $$;

-- ---- Database roles and privileges ----------------------------------------------
-- Group roles (NOLOGIN); real logins are created per environment and granted one of these:
--   erp_app       the application: reads everything except credentials, writes business tables; cannot
--                 change the schema, disable triggers or write the audit trail directly
--   erp_auth      the login service: reads employees, reads and writes credentials
--   erp_readonly  reporting: read only, no credentials
-- The schema itself should be installed and owned by a separate owner role used only for migrations.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_app') THEN CREATE ROLE erp_app NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_auth') THEN CREATE ROLE erp_auth NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_readonly') THEN CREATE ROLE erp_readonly NOLOGIN; END IF;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO erp_app, erp_auth, erp_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO erp_app, erp_readonly;
REVOKE ALL ON user_credentials, user_sessions, acting_context FROM erp_app, erp_readonly;
GRANT INSERT, UPDATE, DELETE ON
  app_users, cities, city_aliases, investors, portfolios, lands, deals, funding_accounts, ledger_accounts,
  journal_entries, journal_lines, capital_movements, land_purchases, deal_costs, deal_sales,
  profit_realizations, realization_costs, distribution_batches, distribution_lines, payouts, documents
  TO erp_app;
GRANT SELECT ON app_users TO erp_auth;
GRANT SELECT, INSERT, UPDATE, DELETE ON user_credentials TO erp_auth;
GRANT SELECT ON user_sessions TO erp_auth;

-- Owner-only functions (seeds, installation, maintenance) and login-service functions.
REVOKE EXECUTE ON FUNCTION erp_bootstrap_admin(text, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION erp_act_as_system() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION erp_assert_no_switch(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION erp_protect_table(regclass) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION erp_open_session(uuid, text, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION erp_revoke_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION erp_open_session(uuid, text, interval) TO erp_auth;
GRANT EXECUTE ON FUNCTION erp_revoke_session(uuid) TO erp_auth;

-- Future tables and functions created by the schema owner are closed to everyone until explicitly
-- granted. (Function EXECUTE must be revoked database-wide: PostgreSQL ignores per-schema revokes of
-- its built-in PUBLIC default.)
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Left to the application:
--   computing each line's amounts (the database verifies them against the rules above);
--   allocating each parcel's share of the purchase price, and recording each expense against the land or
--   parcel it applies to (the database allocates expenses and computes acquisition cost, office fee and
--   distributable profit from them);
--   recording journal entries with the right accounts (the database checks balance, posting and the cash
--   each sale, purchase, expense, capital movement and payout moves, not the choice of non-cash accounts).
