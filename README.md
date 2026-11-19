# Real Estate ERP

Back office for a Saudi real estate investment office that buys land, sells it whole or as subdivided
parcels, and distributes profit to investors directly or through shared portfolios.

The database schema is in `real_estate_erp_schema.sql` (PostgreSQL 15+). The business rules below are
enforced by the database itself (constraints and triggers), not only by application code.

## Running the web MVP (development data only)

Requires Docker and [uv](https://docs.astral.sh/uv/).

```sh
./scripts/dev_setup.sh          # first time: database, schema, Jeddah seed, then choose the Admin password
uv run real-estate-erp serve    # then open http://127.0.0.1:8000
```

`dev_setup.sh` creates `.env` with random development passwords (never committed), starts PostgreSQL 16 on
`127.0.0.1:5433`, installs the schema with Alembic, creates the database logins, loads the Jeddah seed and
creates the administrator **Admin** (`admin@office.local` by default); you choose the password at the
prompt. It is never stored in code or in the database, only its Argon2id hash.

The MVP is FastAPI + Jinja2, Arabic by default (right-to-left) with English, Western digits and SAR:

- **Sign-in**: administrator only in this version. 5 failed attempts lock the account for 15 minutes.
  The session cookie is `HttpOnly`, `Secure` and `SameSite=Strict`; forms carry CSRF tokens. Open the app at
  `http://127.0.0.1:8000` (browsers accept secure cookies on localhost).
- **Dashboard**: summary cards (lands, purchase price, 5% purchase tax, 2.5% Dalalah, total acquisition
  cost), the lands, land status and recent activity from the audit trail.
- **Lands**: the three Jeddah lands with tax, Dalalah and total acquisition cost, and a detail page per land.
- **Investors, Portfolios, Accounting**: read-only overviews; future modules are listed in the navigation.
- **Read-only by design**: every page runs in a database transaction that first verifies the session
  (`erp_act_as`) and is then switched to `READ ONLY`. Sign-in and sign-out are the only writes.

Run the web tests with `./scripts/test_app.sh` (throwaway database, random secrets).

## Business rules

### Tax
- **The only tax in this system is the 5% land purchase tax**, charged once when land is bought.
- There is **no VAT** (or any other tax) on sales, office fees, Dalalah or any other transaction. VAT cannot
  be recorded as an expense.

### Buying land
- Every land purchase carries two charges, computed by the database from the purchase price:
  - **Purchase tax: 5%** (a tax)
  - **Dalalah: 2.5%**: the Land Purchase Brokerage Commission (a commission, not a tax)
- **Acquisition cost = purchase price + purchase tax + Dalalah.** The deal's cash pays the full acquisition
  cost, and the purchase journal entry must pay out exactly that amount.
- These charges apply **only when buying**. A sale never carries them, and they cannot be recorded again
  as deal expenses (nor can office fees).
- Each deal buys one original land, once.

### Cities
- Cities are reference data (`cities`): a stable code, the **Arabic name shown in the UI** (`name_ar`)
  and the English name (`name_en`). `city_aliases` lists every accepted spelling: "جدة", "جده", "Jeddah",
  "Jiddah" and "  JEDDAH " are all the same city.
- A land's city can be entered in any accepted spelling. The database resolves it to `lands.city_code`
  (used to identify the land) and stores the Arabic name in `lands.city`, so the same land can't be
  entered twice under different spellings. Unknown city names are rejected; add new cities to `cities`
  and `city_aliases`.
- Included: Riyadh, Jeddah, Makkah, Madinah, Dammam, Khobar, Taif, Abha.

### Selling land
- A land is sold whole, or subdivided into parcels (which can be subdivided again) that are sold separately.
  A subdivided land cannot also be sold whole, and no land or parcel can be sold twice.
- **Every sale is paid in full** when it is recorded: its journal entry must put exactly the sale amount
  into cash accounts. There are no instalments.
- Each parcel is given its share of the purchase price; its **acquisition cost** is the same share of the
  original land's acquisition cost (so purchase tax and Dalalah are allocated with it). Parcels never total
  more price or area than their land.

### Other expenses
- Each expense (survey, fencing, legal, …) is recorded against the land or parcel it applies to; with no
  land given it applies to the deal's whole land.
- When a sale's profit is approved, the database allocates to it every expense on the sold parcel (in full)
  and on each land it was subdivided from (in proportion to the parcel's share of that land's purchase
  price, the same way acquisition cost is shared). An expense is never allocated beyond its amount.
- Expenses still unallocated once all of a deal's land is sold (for example, paid after the last sale) are
  booked by a **closing realization**: a loss with no office fee and nothing to distribute. A deal can only
  be settled when every expense is allocated.

### Profit and office fees (calculated separately for each completed sale)
```
profit before office fee = sale amount - acquisition cost of the land/parcel sold - expenses allocated to the sale
office fee               = 25% of profit before office fee, only if it is positive (otherwise 0); no tax added
distributable profit     = profit before office fee - office fee   (75% of a positive profit; 0 on a loss)
returnable capital       = acquisition cost + allocated expenses, reduced by any loss
```
- The office fee is charged **once per sale**, at deal level only. Portfolio-funded deals pay it once, in
  the deal's distribution; it is never charged again when a portfolio passes the money to its investors.
- Approving a sale's profit realization makes the database allocate expenses and compute and freeze these
  figures.

**Worked example**

| | SAR |
|---|---:|
| Land purchase price | 1,000,000 |
| Purchase tax (5%) | 50,000 |
| Dalalah (2.5%) | 25,000 |
| **Total acquisition cost** | **1,075,000** |
| Sale price | 1,500,000 |
| Profit before office fees | 425,000 |
| Office fees (25%) | 106,250 |
| **Distributable investor profit** | **318,750** |

### UI labels for purchase charges

| Internal name (database and code) | English UI label | Arabic UI label | Rate |
|---|---|---|---|
| `dalalah` | Land Purchase Brokerage Commission (Dalalah) | دلالة شراء الأرض | 2.5% of the purchase price |
| `purchase_tax` | _not yet specified_ | _not yet specified_ | 5% of the purchase price |
| `total_cost` | _not yet specified_ | _not yet specified_ | price + purchase tax + Dalalah |

Keep the internal name `dalalah` in the database and code; use the labels above only in the UI.

### Distributions
- A deal distribution pays one approved sale's office fee, plus profit and returned capital to direct
  investors and investing portfolios. It can never exceed that sale's office fee, distributable profit or
  returnable capital.
- Profit is split by each holder's share of contributed capital **at the moment the sale was recorded**,
  to the halala. Capital contributed after a sale earns nothing from it. Record times are set by the
  database and cannot be backdated.
- A portfolio passes what it received on to its investors, split by their share, and never more than it
  received.

### Cash and records
- Portfolio cash, deal cash and every investor's capital can never go below zero.
- Every sale, land purchase, expense, capital movement and payout is backed by a posted journal entry that
  moves exactly its amount of cash.
- Capital movements, land purchases and payouts are permanent; corrections are made with compensating entries. Sales and expenses are corrected by reversing the journal
  entry and voiding the record.
- Posted journal entries balance and can only be corrected by an exact reversal.

## Employees, permissions and audit

### Employees and roles
Only internal office employees have accounts (`app_users`); investors and buyers never do. Each employee
has one role:

| Action | Admin | Accountant | Data Entry | Viewer |
|---|:-:|:-:|:-:|:-:|
| View data (never credentials) | ✓ | ✓ | ✓ | ✓ |
| Manage employees and cities | ✓ | | | |
| Investors, portfolios, lands, parcels, deals, funding accounts, documents | ✓ | ✓ | ✓ | |
| Draft journal entries | ✓ | ✓ | ✓ | |
| Ledger accounts | ✓ | ✓ | | |
| Post journal entries; record purchases, sales, expenses, capital movements, payouts | ✓ | ✓ | | |
| Reverse entries; void sales and expenses | ✓ | ✓ | | |
| Prepare profit realizations and distributions | ✓ | ✓ | | |
| **Approve profit realizations and distributions; mark paid or cancelled** | ✓ | | | |
| **Settle deals; close portfolios** | ✓ | | | |

Employees are never deleted (disable them), nobody can change their own role or status, and the built-in
**system** user (used by seeds) has Data Entry rights only and can never log in.

### Four-eyes rule
Whoever prepares a financial record can never post or approve it, **whatever their role, admins included**:
a journal entry can't be posted by its preparer or anyone who added a line; a profit realization can't be
approved by its preparer; a distribution can't be approved, paid or cancelled by its preparer or anyone who
added a line; a deal can't be settled, or a portfolio closed, by whoever created it. If no eligible second
employee exists, the record simply stays pending.

Because a transaction can act as only **one** employee (see below), preparing a record and posting or
approving it always happen in **separate transactions by different employees**: a single transaction can
never do both, even if the application holds both employees' valid session tokens.

### Sessions and the acting employee
1. The login service (database role `erp_auth`) verifies the employee's password, generates a long random
   token and opens a session: `SELECT erp_open_session('<employee id>', '<token>');`. Only the token's
   SHA-256 hash is stored; sessions expire (default 8 hours, at most 24) and can be revoked.
2. The application starts **every** transaction with the employee's token:

```sql
SELECT erp_act_as('<session token>');
```

The database verifies the token and records the employee for **that transaction only**, in a table the
application cannot read or write. Nothing the application sets in its own session (such as `set_config`) is
used to decide who is acting, and the identity never carries over to the next transaction on a pooled
connection. **One employee per transaction:** once an employee is acting, switching to anyone else in the
same transaction is refused, even with that employee's valid token (naming the same employee again is
fine). `erp_end_session()` logs the current session out.

Any write without a verified acting employee is rejected, as are expired, revoked or forged tokens and
disabled employees. The database stamps who and when on every record
(`created_by/at`, `updated_by/at`, and `posted`, `reversed`, `approved`, `paid`, `cancelled`, `voided`,
`settled`, `closed` by/at); values sent by the application for these columns are ignored.

### Soft deletion
Investors, lands, portfolios, deals, funding accounts, ledger accounts, documents and cities are **never
deleted**: set `is_active = false` instead. Deactivation records who and when (`deactivated_by/at`), is
audited (`deactivate` / `reactivate`), and inactive records cannot be used for anything new (a new deal on an
inactive land, a new member of an inactive portfolio, a journal line on an inactive ledger account, …).
Unfinished drafts (draft journal entries and lines, draft realizations and distributions) can still be
deleted; posted and approved records are permanent.

### Tables added in the future
Every table in schema `public` is protected by the permission, stamp and audit triggers. A table created
later gets them automatically (event trigger `erp_protect_new_tables`) and is unusable by the application
until it is granted and has a permission rule in `erp_authorize`. New tables and functions are closed to
the application roles by default. `SELECT * FROM erp_unprotected_tables();` must always return nothing (the
test suite checks it). Installing the event trigger needs a superuser; without one the schema installs
with a warning and new tables must be protected with `erp_protect_table()`.

### Audit trail
Every insert, update and delete on employee, master-data and financial tables is written to
`audit_events`: employee, time, transaction id, action (`create`, `post`, `reverse`, `approve`, `pay`,
`cancel`, `void`, `settle`, `close`, `role_change`, `credential_*`, …) and the values before and after.
Password hashes are never logged. Audit records can never be changed, deleted or truncated.

### Database roles
| Role | Use |
|---|---|
| `erp_app` | The application. Reads everything except credentials; writes business tables. Cannot change the schema, disable triggers, write the audit trail directly, or create the first admin. |
| `erp_auth` | The future login service. Reads employees; reads and writes `user_credentials`. |
| `erp_readonly` | Reporting. Read only, no credentials. |

These are group roles (no login); create one login per environment and grant it the right role. Install
and own the schema with a separate owner role used only for migrations. On a new installation, the owner
creates the first admin once with `SELECT erp_bootstrap_admin('<name>', '<email>');`. Seeds and maintenance
scripts run as the owner and act as the built-in system user with `erp_act_as_system()`; the application
can call neither.

`user_credentials` stores only an **Argon2id hash** produced by the application, never a plain password,
plus lockout and MFA fields for the future login service.

## Development seed data

`db/seeds/` holds sample data for **local development only**. It is never loaded by the schema or by
production; each seed refuses to run unless explicitly flagged as development:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v seed_env=development -f db/seeds/dev_jeddah_lands.sql
```

`dev_jeddah_lands.sql` adds three Jeddah (جدة) lands as **prospective** (not yet bought), with only the
facts provided: plan number, plot number, area, street width and purchase price. It creates no investors,
deals, purchase dates, bank transactions or accounting entries. It is idempotent: re-running it never
duplicates a land and never alters a land that has moved past prospective.

Their 5% purchase tax and 2.5% Dalalah are shown by the `land_acquisition_preview` view, which uses the same
rule functions (`purchase_tax_amount`, `dalalah_amount`, `acquisition_cost_amount`) as recorded purchases:

| Plan | Plot | Area | Street | Purchase price | Purchase tax (5%) | Dalalah (2.5%) | Total acquisition cost |
|---|---|---:|---:|---:|---:|---:|---:|
| 99/أ | 1200 | 900 m² | 16 m | 1,500,000 | 75,000 | 37,500 | 1,612,500 |
| 29/ب | 400 | 900 m² | 16 m | 1,200,000 | 60,000 | 30,000 | 1,290,000 |
| 87 | 560 | 880 m² | 16 m | 1,700,000 | 85,000 | 42,500 | 1,827,500 |

## Running the schema tests

Requires Docker.

```sh
./scripts/test_schema.sh
```

This loads the schema into a throwaway PostgreSQL 16 container, runs `tests/sql/schema_test.sql`, then
tests the development seed in a separate empty database (`tests/sql/seed_test.sql`: refused without the
flag, run twice with it). It prints a PASS/FAIL line per test (rejections show the database's error
message) and exits non-zero on any failure.

The tests run as the restricted application role and follow the same rules as the application: each test
transaction acts as exactly one employee, and journal entries a test needs posted are drafted by a second
employee in a separate, committed database session (via the `dblink` extension, test database only).
Use `POSTGRES_IMAGE` to test against another PostgreSQL version (15+).
