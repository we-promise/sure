# Scalable Capital (self-hosted preview)

Sure uses the official Scalable CLI to read a personal EUR broker portfolio and its uninvested cash balance. Sure creates an investment account for securities and a separate Cash account for idle cash, deposits, withdrawals, dividends, interest, and fees. Sure also discovers a personal Tagesgeld account when Scalable can select one. It creates that Cash account once the balance is positive and keeps it linked if the balance later returns to zero.

The first sync fetches 90 days of available history. After it succeeds, Sure stores a cutoff for each feed in its database. Following syncs import events from the saved cutoff onward, including newly settled events reported with a later activity timestamp. Broker transaction IDs make retries and duplicate pages safe. If a read or import fails, the cutoff stays at the last successful sync.

Buys, sells, and identifiable securities transfers feed the investment ledger. Trade cash settlements move between the investment and cash ledgers as paired internal transfers. Sure records the broker’s net cash amounts and execution prices, and uses reconciled fee and tax details when supplied. The trade date and intraday order use the last fill time when available, with the broker’s last activity time as a fallback. Other cash transfers are imported on their originating accounts and use Sure’s normal transfer matching. Holdings use Scalable’s reported per-share cost when available. Sure uses a ticker only when a configured market-data provider confirms the exact ISIN, preferring EUR listings. Otherwise the ISIN identifies the holding. Fixed-term savings and native crypto are outside this preview.

## Configure the server

1. Install a verified [Scalable CLI 1.2.0](https://github.com/ScalableCapital/scalable-cli/releases/tag/v1.2.0) binary for your server architecture. The Linux binary requires glibc 2.38 or later. For Docker or Unraid, mount the verified binary read-only at the configured path in the Sure worker container. The operator is responsible for supplying a compatible runtime.
2. Use a private CLI configuration and session directory owned by the Unix user running the worker. On Linux, set `XDG_CONFIG_HOME` for both setup and the worker, and persist the directory across container restarts. On hosts without Secret Service, set `session_backend = "file"` under `[auth]` in `$XDG_CONFIG_HOME/scalable-cli/config.toml` and restrict access to the directory. [Scalable CLI configuration](https://github.com/ScalableCapital/scalable-cli/blob/v1.2.0/public-docs/configuration.md)
3. Enable CLI access in your Scalable web profile. As the worker user in that same environment, run `sc login --local-read-only` and complete the device-code flow in your browser. Use `sc broker portfolios --json` to find the portfolio ID. If Scalable has multiple active Overnight Savings accounts, use the personal account ID in the setup form. The CLI prints the available IDs when you run `sc overnight --json`.
4. Set `SCALABLE_CAPITAL_CLI_PATH` to the absolute executable path and `SCALABLE_CAPITAL_FAMILY_ID` to the UUID of the one Sure household authorized to use the session. Set both variables on the Sure web and worker processes. You can retrieve the UUID with `bin/rails runner 'puts User.find_by!(email: ARGV.fetch(0)).family_id' ADMIN_EMAIL` in the Sure container.

A household administrator can then enable **Preview features**, open **Settings → Bank Sync → Scalable Capital**, and enter the IDs. Use a dedicated Scalable session for this connector. Sure stores the account IDs and imported financial data. The CLI manages broker credentials and signing keys. Sure invokes only read commands, and Scalable’s CLI mode also blocks broker write commands locally.

[Bank Sync setup screenshot](scalable-capital-setup.png)

## Sync and reconnect

The connection follows Sure’s regular sync schedule. Use the Bank Sync refresh button for an immediate sync. Scalable requires interactive sign-in after 24 hours without an authenticated request or at most seven days from the last sign-in. Run `sc login --local-read-only` again in the worker's CLI environment, then resync the existing connection. Sure verifies the Scalable account ID on each sync.

Disconnecting leaves the imported Sure accounts as manual accounts and removes the link. Reconnecting creates fresh linked accounts. Review any existing Scalable accounts for overlapping balances before connecting.
