-- Executing a matured timelock operation requires the salt it was scheduled with. OpenZeppelin's
-- TimelockController emits it in a separate CallSalt event (only when non-zero), right after
-- CallScheduled in the same transaction.
ALTER TABLE timelock_calls ADD COLUMN IF NOT EXISTS salt TEXT NOT NULL DEFAULT '0x0000000000000000000000000000000000000000000000000000000000000000';
