# Monobank integration runtime configuration.
#
# Monobank's personal API allows one request per minute per endpoint and caps a single
# statement request at 31 days, so these settings exist to bound how much work one sync
# may do rather than to tune performance.
Rails.application.configure do
  # Whether held (unsettled) transactions are imported and shown with a "Pending" badge.
  # Default: true. Set MONOBANK_INCLUDE_PENDING=0 to import only settled transactions.
  config.x.monobank.include_pending = !ENV["MONOBANK_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[0 false no])

  # How many statement requests one sync may spend across all of the connection's
  # accounts. Each request costs roughly a minute of throttled waiting, so the default
  # keeps a sync to a few minutes; accounts that do not fit in the budget are picked up
  # by the next sync (least-recently-covered first).
  config.x.monobank.max_statement_requests_per_sync =
    ENV.fetch("MONOBANK_MAX_STATEMENT_REQUESTS_PER_SYNC", 4).to_i.clamp(1, 60)

  # How far back every sync re-reads the statement, regardless of when the last sync
  # ran. Holds have to stay visible in the payload to avoid being pruned as stale, and
  # Monobank may also settle a transaction under a different id than the hold it
  # replaces, so a few days of overlap keeps pending entries accurate.
  config.x.monobank.pending_lookback_days =
    ENV.fetch("MONOBANK_PENDING_LOOKBACK_DAYS", 3).to_i.clamp(1, 31)

  # How much history a brand-new connection reaches for when no explicit start date is
  # set. Anything beyond one statement window is backfilled across later syncs.
  config.x.monobank.initial_history_days =
    ENV.fetch("MONOBANK_INITIAL_HISTORY_DAYS", 31).to_i.clamp(1, 3650)

  # Debug logging for raw Monobank API responses.
  # DEVELOPMENT-ONLY: the raw dump contains PII (merchant names, counterparty names and
  # IBANs, amounts, account ids) and is gated to local environments so it never fires in
  # managed/production.
  # Default: false (only log summary info)
  config.x.monobank.debug_raw = ENV["MONOBANK_DEBUG_RAW"].to_s.strip.downcase.in?(%w[1 true yes])
end
