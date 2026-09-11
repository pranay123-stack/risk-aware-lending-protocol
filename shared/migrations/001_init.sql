-- Schema for the lending protocol indexer, API and risk monitor.
--
-- Two kinds of data live here, and they are handled differently:
--
--   1. CHAIN-DERIVED rows (events and everything decoded from them). Every such row references
--      blocks(number) ON DELETE CASCADE, so rolling back a reorg is one DELETE on `blocks`.
--   2. OBSERVATIONS made by the monitor at wall-clock time (market/risk snapshots, alerts). These
--      are measurements, not chain facts, and are never rolled back.
--
-- Token amounts, indexes and rates are uint256 on-chain and stored as NUMERIC(78,0): exact, no
-- floating point anywhere between the chain and the API.

-- deployment_key = "<chainId>:<pool address>". A different key at startup means a new chain or a
-- redeploy (e.g. a restarted Anvil), and the chain-derived tables are wiped before indexing.
CREATE TABLE IF NOT EXISTS indexer_cursor (
    id              TEXT PRIMARY KEY,
    deployment_key  TEXT NOT NULL,
    block_number    BIGINT NOT NULL,
    block_hash      TEXT NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Only blocks that contain relevant logs, plus every batch-end block, are stored. Block hashes
-- chain, so an unchanged hash at height N proves every block <= N is unchanged too.
CREATE TABLE IF NOT EXISTS blocks (
    number          BIGINT PRIMARY KEY,
    hash            TEXT NOT NULL,
    parent_hash     TEXT NOT NULL,
    timestamp       TIMESTAMPTZ NOT NULL
);

-- Raw, fully decoded log for every event the indexer understands (the audit trail).
CREATE TABLE IF NOT EXISTS events (
    tx_hash         TEXT NOT NULL,
    log_index       INTEGER NOT NULL,
    block_number    BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time      TIMESTAMPTZ NOT NULL,
    contract        TEXT NOT NULL,
    source          TEXT NOT NULL,          -- pool | configurator | oracle | feed | timelock | vault | acl
    name            TEXT NOT NULL,
    args            JSONB NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS events_block_idx ON events (block_number DESC, log_index DESC);
CREATE INDEX IF NOT EXISTS events_name_idx ON events (name, block_number DESC);

-- ---------------------------------------------------------------- typed user activity
CREATE TABLE IF NOT EXISTS supplies (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL, user_address TEXT NOT NULL, caller TEXT NOT NULL,
    amount NUMERIC(78,0) NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE TABLE IF NOT EXISTS withdrawals (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL, user_address TEXT NOT NULL, to_address TEXT NOT NULL,
    amount NUMERIC(78,0) NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE TABLE IF NOT EXISTS borrows (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL, user_address TEXT NOT NULL,
    amount NUMERIC(78,0) NOT NULL, borrow_rate NUMERIC(78,0) NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE TABLE IF NOT EXISTS repays (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL, user_address TEXT NOT NULL, repayer TEXT NOT NULL,
    amount NUMERIC(78,0) NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE TABLE IF NOT EXISTS collateral_toggles (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL, user_address TEXT NOT NULL, enabled BOOLEAN NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE TABLE IF NOT EXISTS liquidations (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    collateral_asset TEXT NOT NULL, debt_asset TEXT NOT NULL,
    borrower TEXT NOT NULL, liquidator TEXT NOT NULL,
    debt_repaid NUMERIC(78,0) NOT NULL, collateral_seized NUMERIC(78,0) NOT NULL,
    receive_supply BOOLEAN NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS liquidations_time_idx ON liquidations (block_number DESC);
CREATE INDEX IF NOT EXISTS liquidations_borrower_idx ON liquidations (borrower);

CREATE TABLE IF NOT EXISTS bad_debt_events (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL, borrower TEXT NOT NULL,
    amount NUMERIC(78,0) NOT NULL, covered_by_treasury NUMERIC(78,0) NOT NULL,
    deficit_added NUMERIC(78,0) NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);

-- ---------------------------------------------------------------- reserve & oracle history
CREATE TABLE IF NOT EXISTS reserve_updates (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    reserve TEXT NOT NULL,
    liquidity_rate NUMERIC(78,0) NOT NULL, borrow_rate NUMERIC(78,0) NOT NULL,
    liquidity_index NUMERIC(78,0) NOT NULL, borrow_index NUMERIC(78,0) NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS reserve_updates_reserve_idx ON reserve_updates (reserve, block_number DESC, log_index DESC);

CREATE TABLE IF NOT EXISTS price_updates (
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    feed TEXT NOT NULL, asset TEXT, feed_role TEXT NOT NULL,   -- primary | secondary
    answer NUMERIC(78,0) NOT NULL, round_id NUMERIC(78,0) NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS price_updates_asset_idx ON price_updates (asset, block_number DESC);

-- ---------------------------------------------------------------- governance
-- One row per scheduled timelock call (a batch produces several rows with the same op_id).
CREATE TABLE IF NOT EXISTS timelock_calls (
    op_id TEXT NOT NULL, call_index INTEGER NOT NULL,
    target TEXT NOT NULL, value NUMERIC(78,0) NOT NULL, data TEXT NOT NULL,
    predecessor TEXT NOT NULL, delay_seconds BIGINT NOT NULL,
    scheduled_tx TEXT NOT NULL,
    scheduled_block BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    scheduled_time TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (op_id, call_index)
);
CREATE TABLE IF NOT EXISTS timelock_outcomes (
    op_id TEXT NOT NULL, outcome TEXT NOT NULL,       -- executed | cancelled
    tx_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
    block_number BIGINT NOT NULL REFERENCES blocks(number) ON DELETE CASCADE,
    block_time TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (tx_hash, log_index)
);

-- Every address that has ever interacted, derived from events (reorg-safe by construction).
CREATE OR REPLACE VIEW accounts AS
    SELECT user_address AS address, min(block_number) AS first_block, max(block_number) AS last_block
    FROM (
        SELECT user_address, block_number FROM supplies
        UNION ALL SELECT user_address, block_number FROM withdrawals
        UNION ALL SELECT user_address, block_number FROM borrows
        UNION ALL SELECT user_address, block_number FROM repays
        UNION ALL SELECT user_address, block_number FROM collateral_toggles
        UNION ALL SELECT borrower, block_number FROM liquidations
        UNION ALL SELECT liquidator, block_number FROM liquidations
    ) a
    GROUP BY user_address;

-- ---------------------------------------------------------------- monitor observations
CREATE TABLE IF NOT EXISTS market_snapshots (
    id BIGSERIAL PRIMARY KEY,
    taken_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    block_number BIGINT NOT NULL,
    reserve TEXT NOT NULL, symbol TEXT NOT NULL, decimals INTEGER NOT NULL,
    price NUMERIC(78,0) NOT NULL, price_status TEXT NOT NULL,
    total_supplied NUMERIC(78,0) NOT NULL, total_borrowed NUMERIC(78,0) NOT NULL,
    cash NUMERIC(78,0) NOT NULL, utilization NUMERIC(78,0) NOT NULL,
    liquidity_rate NUMERIC(78,0) NOT NULL, borrow_rate NUMERIC(78,0) NOT NULL,
    treasury NUMERIC(78,0) NOT NULL, deficit NUMERIC(78,0) NOT NULL,
    supplied_usd DOUBLE PRECISION NOT NULL, borrowed_usd DOUBLE PRECISION NOT NULL
);
CREATE INDEX IF NOT EXISTS market_snapshots_reserve_idx ON market_snapshots (reserve, taken_at DESC);

CREATE TABLE IF NOT EXISTS risk_snapshots (
    id BIGSERIAL PRIMARY KEY,
    taken_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    block_number BIGINT NOT NULL,
    account TEXT NOT NULL,
    priced BOOLEAN NOT NULL,
    health_factor NUMERIC(78,0),
    collateral_usd DOUBLE PRECISION NOT NULL,
    debt_usd DOUBLE PRECISION NOT NULL,
    borrow_capacity_usd DOUBLE PRECISION NOT NULL,
    level TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS risk_snapshots_account_idx ON risk_snapshots (account, taken_at DESC);

CREATE OR REPLACE VIEW account_risk_latest AS
    SELECT DISTINCT ON (account) * FROM risk_snapshots ORDER BY account, taken_at DESC, id DESC;

CREATE TABLE IF NOT EXISTS alerts (
    id BIGSERIAL PRIMARY KEY,
    kind TEXT NOT NULL,
    severity TEXT NOT NULL,             -- info | warning | critical
    subject TEXT NOT NULL,              -- account or reserve address, or "protocol"
    message TEXT NOT NULL,
    data JSONB NOT NULL DEFAULT '{}'::jsonb,
    opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ
);
-- At most one open alert per (kind, subject): the monitor refreshes it instead of spamming.
CREATE UNIQUE INDEX IF NOT EXISTS alerts_open_unique ON alerts (kind, subject) WHERE resolved_at IS NULL;
