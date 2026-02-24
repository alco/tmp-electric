---
'@core/sync-service': patch
---

Implement a write mode in shape consumer that can write transaction fragments directly to the shape log, without buffering the complete transaction in memory.

The Storage behaviour now includes three new optional callbacks for fragment streaming:

- `append_fragment_to_log!/2` — writes log items for a transaction fragment without advancing the committed transaction boundary.
- `signal_txn_commit!/2` — advances the committed transaction boundary after all fragments have been written.
- `supports_txn_fragment_streaming?/0` — returns `true` if the backend implements the above two callbacks.

Custom storage backends that do not implement these callbacks will automatically fall back to the default `write_unit=txn` mode (full transaction buffering) with a warning logged at startup.
