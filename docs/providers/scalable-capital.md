# Scalable Capital (self-hosted preview)

Sure uses the official Scalable CLI to discover the broker portfolios and Overnight Savings accounts accessible to the signed-in user. Pick the accounts you want to sync in Bank Sync. Sure creates an investment account and a separate Cash account for each selected broker portfolio. It creates a selected Tagesgeld Cash account once the balance is positive and keeps it linked if the balance later returns to zero. Junior Tagesgeld accounts require explicit selection and are private by default.

The first sync fetches 90 days of available history. After it succeeds, Sure stores a cutoff for each feed in its database. Following syncs import events from the saved cutoff onward, including newly settled events reported with a later activity timestamp. Broker transaction IDs make retries and duplicate pages safe. If a read or import fails, the cutoff stays at the last successful sync.

Buys, sells, and identifiable securities transfers feed the investment ledger. Trade cash settlements move between the investment and cash ledgers as paired internal transfers. Sure records the broker’s net cash amounts and execution prices. It keeps separate fees and taxes unless linked trade details show that they are included in the settlement. The trade date and intraday order use the last fill time when available, with the broker’s last activity time as a fallback. Other cash transfers use Sure’s normal transfer matching. Sure imports reciprocally linked, fully priced securities exchanges when both legs have equal value and different ISINs. It books an IPO only when the feed identifies a completed purchase with execution details. Cash reservations and unsupported or ambiguous corporate actions are outside the preview.

Sure calculates each brokerage balance from the holdings in its inventory response and dates it when the inventory is read. Holdings use Scalable’s reported per-share cost when available. Sure uses a ticker only when a configured market-data provider confirms the exact ISIN, preferring EUR listings. Otherwise the ISIN identifies the holding. The CLI does not identify children’s broker depots or Altersvorsorgedepots as separate product types in discovery. Those products, fixed-term savings, and native crypto remain outside the documented preview.

## Configure the server

1. Install a verified [Scalable CLI 1.3.0](https://github.com/ScalableCapital/scalable-cli/releases/tag/v1.3.0) binary for your server architecture. The Linux binary requires glibc 2.38 or later. For Docker or Unraid, mount the verified binary read-only at the configured path in the Sure worker container. The operator is responsible for supplying a compatible runtime.
2. Use a private CLI configuration and session directory owned by the Unix user running Sure. On Linux, set `XDG_CONFIG_HOME` for the web and worker processes, and persist the directory across container restarts. On hosts without Secret Service, set `session_backend = "file"` under `[auth]` in `$XDG_CONFIG_HOME/scalable-cli/config.toml` and restrict access to the directory. [Scalable CLI configuration](https://github.com/ScalableCapital/scalable-cli/blob/v1.3.0/public-docs/configuration.md)
3. Enable CLI access in your Scalable web profile. As the Sure service user in that same environment, run `sc login --local-read-only` and complete the device-code flow in your browser.
4. Set `SCALABLE_CAPITAL_CLI_PATH` to the absolute executable path and `SCALABLE_CAPITAL_FAMILY_ID` to the UUID of the one Sure household authorized to use the session. Set both variables on the Sure web and worker processes. You can retrieve the UUID with `bin/rails runner 'puts User.find_by!(email: ARGV.fetch(0)).family_id' ADMIN_EMAIL` in the Sure container.

A household administrator can then enable **Preview features**, open **Settings → Bank Sync → Scalable Capital**, choose **Connect Scalable Capital**, and select accounts to sync. The CLI can truncate the list when multiple Overnight Savings accounts are available. When Sure cannot verify the complete list, the picker displays a warning and still offers broker portfolios. Use a dedicated Scalable session for this connector. Sure invokes only read commands. The CLI manages broker credentials and signing keys and enforces local read-only mode.

[Bank Sync setup screenshot](scalable-capital-setup.png)

## Sync and reconnect

The connection follows Sure’s regular sync schedule. Use the Bank Sync refresh button for an immediate sync. Scalable requires interactive sign-in after 24 hours without an authenticated request or at most seven days from the last sign-in. Run `sc login --local-read-only` again in the worker's CLI environment, then resync the existing connection. Sure verifies the Scalable account ID on each sync.

Disconnecting leaves the imported Sure accounts as manual accounts and removes the link. Reconnecting creates fresh linked accounts. Review any existing Scalable accounts for overlapping balances before connecting.
