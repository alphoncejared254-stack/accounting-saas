-- ============
-- Accounting SaaS (PostgreSQL)
-- Core: multi-tenant + double-entry ledger
-- ============

-- Enable UUID generation (Postgres 13+ typically supports this extension)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------
-- Tenancy & Auth (minimal)
-- ----------
CREATE TABLE organizations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  base_currency char(3) NOT NULL DEFAULT 'USD',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text UNIQUE NOT NULL,
  full_name     text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE organization_members (
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role            text NOT NULL CHECK (role IN ('owner','admin','accountant','viewer')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, user_id)
);

-- ----------
-- Chart of Accounts
-- ----------
CREATE TABLE accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  code            text NOT NULL,                 -- e.g. 1000, 4000
  name            text NOT NULL,                 -- e.g. Cash, Sales Revenue
  type            text NOT NULL CHECK (type IN ('asset','liability','equity','income','expense')),
  currency        char(3),                       -- NULL means org base currency

  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  UNIQUE (organization_id, code)
);

CREATE INDEX idx_accounts_org ON accounts(organization_id);

-- ----------
-- Journal Entries (header)
-- ----------
CREATE TABLE journal_entries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,

  entry_date      date NOT NULL,
  reference       text,                          -- invoice number, receipt id, etc.
  memo            text,

  status          text NOT NULL DEFAULT 'posted'
                  CHECK (status IN ('draft','posted','voided')),
  created_by      uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  posted_at       timestamptz,

  -- Optional: prevent editing after posting in app logic.
  -- Database will still allow updates unless you add triggers (later).
  CHECK ((status <> 'posted') OR (posted_at IS NOT NULL))
);

CREATE INDEX idx_journal_entries_org_date ON journal_entries(organization_id, entry_date);

-- ----------
-- Journal Lines (debits/credits)
-- ----------
CREATE TABLE journal_lines (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  journal_entry_id uuid NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,

  account_id       uuid NOT NULL REFERENCES accounts(id),
  description      text,

  -- Use NUMERIC for money (safe, exact). Store in minor units only if you prefer.
  debit            numeric(18,2) NOT NULL DEFAULT 0,
  credit           numeric(18,2) NOT NULL DEFAULT 0,
  currency         char(3), -- NULL means account/org currency

  created_at       timestamptz NOT NULL DEFAULT now(),

  CHECK (debit >= 0),
  CHECK (credit >= 0),
  CHECK (NOT (debit > 0 AND credit > 0)),
  CHECK (debit > 0 OR credit > 0)
);

CREATE INDEX idx_journal_lines_entry ON journal_lines(journal_entry_id);
CREATE INDEX idx_journal_lines_account ON journal_lines(account_id);
CREATE INDEX idx_journal_lines_org ON journal_lines(organization_id);

-- ----------
-- Integrity helper: Ensure lines match entry org + account org
-- (Enforced via app logic for now. Later we can add triggers.)
-- ----------

-- ----------
-- View: account balances (derived, never stored)
-- ----------
CREATE VIEW v_account_balances AS
SELECT
  a.organization_id,
  a.id AS account_id,
  a.code,
  a.name,
  a.type,
  COALESCE(a.currency, o.base_currency) AS currency,
  SUM(jl.debit)  AS total_debits,
  SUM(jl.credit) AS total_credits,
  SUM(jl.debit - jl.credit) AS net_balance
FROM accounts a
JOIN organizations o ON o.id = a.organization_id
LEFT JOIN journal_lines jl ON jl.account_id = a.id
LEFT JOIN journal_entries je ON je.id = jl.journal_entry_id
  AND je.status = 'posted'
GROUP BY a.organization_id, a.id, a.code, a.name, a.type, COALESCE(a.currency, o.base_currency);
