# Real Estate ERP

Back office for a Saudi real estate investment office that buys land, sells it whole or as subdivided
parcels, and distributes profit to investors directly or through shared portfolios.

The database schema is in `real_estate_erp_schema.sql` (PostgreSQL 15+). The business rules below are
enforced by the database itself (constraints and triggers), not only by application code.

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

## Running the schema tests

Requires Docker.

```sh
./scripts/test_schema.sh
```

This loads the schema into a throwaway PostgreSQL 16 container, runs `tests/sql/schema_test.sql`, prints
a PASS/FAIL line per test (rejections show the database's error message), and exits non-zero on any failure.
Use `POSTGRES_IMAGE` to test against another PostgreSQL version (15+).
