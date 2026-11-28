# Scalable Capital (self-hosted preview)

Sure uses the official Scalable CLI to discover the broker portfolios and Overnight Savings accounts accessible to the signed-in user. Pick the accounts you want to sync in Bank Sync. Sure creates an investment account and a separate Cash account for each selected broker portfolio. It creates a selected Tagesgeld Cash account once the balance is positive and keeps it linked if the balance later returns to zero. Junior Tagesgeld accounts require explicit selection and do not inherit automatic family-wide sharing.

The first sync fetches 90 days of available history. After it succeeds, Sure stores a cutoff for each feed in its database. Following syncs import events from the saved cutoff onward, including newly settled events reported with a later activity timestamp. Broker transaction IDs make retries and duplicate pages safe. If a read or import fails, the cutoff stays at the last successful sync.

Buys, sells, and identifiable securities transfers feed the investment ledger. Trade cash settlements move between the investment and cash ledgers as paired internal transfers. Sure records the broker’s net cash amounts and execution prices. It keeps separate fees and taxes unless linked trade details show that they are included in the settlement. The trade date and intraday order use the last fill time when available, with the broker’s last activity time as a fallback. Other cash transfers use Sure’s normal transfer matching. Sure imports reciprocally linked, fully priced securities exchanges when both legs have equal value and different ISINs. It books an IPO only when the feed identifies a completed purchase with execution details. Cash reservations and unsupported or ambiguous corporate actions are outside the preview.

Sure calculates each brokerage balance from the holdings in its inventory response and dates it when the inventory is read. Holdings use Scalable’s reported per-share cost when available. Sure uses a ticker only when a configured market-data provider confirms the exact ISIN, preferring EUR listings. Otherwise the ISIN identifies the holding. The CLI does not identify children’s broker depots or Altersvorsorgedepots as separate product types in discovery. Those products, fixed-term savings, and native crypto remain outside the documented preview.

## Configure Docker or Unraid

Sure's Linux Docker images for AMD64 and ARM64 bundle [Scalable CLI 1.3.0](https://github.com/ScalableCapital/scalable-cli/releases/tag/v1.3.0) at `/usr/local/bin/sc`. Image builds check the archive against a checksum pinned from Scalable's signed manifest. Sure redistributes the release binary and its notices under `/opt/scalable-cli`.

1. Add `SCALABLE_CAPITAL_FAMILY_ID=<household UUID>` to your Compose `.env`. Retrieve the household UUID with `docker compose exec -T web bin/rails runner 'puts User.find_by!(email: ARGV.fetch(0)).family_id' ADMIN_EMAIL`.
2. Use the `scalable-cli-state` volume and family ID configuration from [Sure's Compose example](../../compose.example.yml). For an existing Compose file or Unraid templates, set `SCALABLE_CAPITAL_FAMILY_ID` on both web and worker and mount the same private persistent directory at `/home/rails/.config/scalable-cli` in both containers. The Docker image presets file-based sessions. If you use an empty bind mount, give UID `1000` write access and create `config.toml` with `[auth]` and `session_backend = "file"` before signing in. Keep this volume separate from the uploads volume and Sure backups.
3. Recreate web and worker to apply the configuration. Enable CLI access in your Scalable web profile, run `docker compose exec worker sc login --local-read-only`, and complete the device-code flow in your browser. On Unraid, run the same `sc login --local-read-only` command in the worker container's console as the user running Sure.

## Configure a source installation

Install a verified [Scalable CLI release](https://github.com/ScalableCapital/scalable-cli/releases/tag/v1.3.0) and set `SCALABLE_CAPITAL_CLI_PATH` to its absolute path. The Linux binary requires glibc 2.38 or later. Set `SCALABLE_CAPITAL_FAMILY_ID` on both processes, use the same private CLI configuration directory for web and worker, and run `sc login --local-read-only` as the Sure service user. [Scalable CLI configuration](https://github.com/ScalableCapital/scalable-cli/blob/v1.3.0/public-docs/configuration.md)

## Select accounts

A household administrator can then enable **Preview features**, open **Settings → Bank Sync → Scalable Capital**, choose **Connect Scalable Capital**, and select accounts to sync. The CLI can truncate the list when multiple Overnight Savings accounts are available. When Sure cannot verify the complete list, the picker displays a warning and still offers broker portfolios. Use a dedicated Scalable session for this connector. Sure invokes only read commands. The CLI manages broker credentials and signing keys and enforces local read-only mode.

[Bank Sync setup screenshot](scalable-capital-setup.png)

## Sync and reconnect

The connection follows Sure’s regular sync schedule. Use the Bank Sync refresh button for an immediate sync. Scalable requires interactive sign-in after 24 hours without an authenticated request or at most seven days from the last sign-in. Run `sc login --local-read-only` again in the worker's CLI environment, then resync the existing connection. Sure verifies the Scalable account ID on each sync.

Disconnecting leaves the imported Sure accounts as manual accounts and removes the link. Reconnecting creates fresh linked accounts. Review any existing Scalable accounts for overlapping balances before connecting.

## Roll back to an older preview

The older preview supports one brokerage and one optional personal Overnight Savings account. Sure can convert a picker connection back to that format when it has one brokerage and one explicitly selected personal Overnight Savings account, with matching account links and no conflicting sync state. The rollback carries over both account IDs and sync checkpoints and keeps the linked Sure accounts. The older preview automatically discovers savings when no ID is configured, so a brokerage-only picker selection cannot be converted safely.

Before attempting a rollback, stop Sure’s web and worker services and back up the current database. If the rollback reports an incompatible connection, keep the current build and run its migrations forward before restarting the services. To return to an older build, restore a pre-upgrade backup with the matching Sure version in a separate instance. Keep the current database for records added since the backup.

## Securities prices

After connecting a brokerage, open **Settings → Self-hosting → Financial Data Providers** and enable **Scalable Capital** under **Securities Providers**. The same read-only CLI session supplies security search, consolidated quotes, and available daily prices for supported ISINs. The CLI identifies securities by ISIN. For new Scalable holdings, Sure still prefers a verified ticker from other enabled providers and uses the ISIN when Scalable supplies the price feed. Exchange rates use the separately selected exchange rate provider.
