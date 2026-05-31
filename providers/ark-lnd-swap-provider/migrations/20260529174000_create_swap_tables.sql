CREATE TABLE IF NOT EXISTS swaps (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    amount_sat INTEGER,
    preimage_hash TEXT,
    preimage TEXT,
    bolt11 TEXT,
    asset_id TEXT,
    asset_amount TEXT,
    ark_wallet_dir TEXT,
    ark_recipient TEXT,
    ln_result TEXT,
    ark_result TEXT,
    metadata TEXT,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS swap_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    swap_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    details TEXT,
    created_at INTEGER NOT NULL
);
