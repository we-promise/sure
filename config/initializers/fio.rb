# frozen_string_literal: true

# Fio banka sync tuning. Every value is optional; the defaults suit a personal account.
Rails.application.configure do
  # How far back a brand-new connection reaches on its first sync. Fio serves 90 days
  # without additional authorization; anything older needs the account's full history
  # unlocked in internet banking for 10 minutes (Provider::Fio::HistoryLockedError).
  config.x.fio.initial_history_days =
    ENV.fetch("FIO_INITIAL_HISTORY_DAYS", 90).to_i.clamp(1, 3650)

  # Days before the last covered day that each subsequent sync re-reads. Movements carry
  # their booking date, which can be a few days behind the day they appear, so the window
  # overlaps rather than starting where the last one ended. Re-reading is free: entries
  # are matched on Fio's movement id.
  config.x.fio.sync_lookback_days =
    ENV.fetch("FIO_SYNC_LOOKBACK_DAYS", 7).to_i.clamp(1, 90)

  # When truthy, logs the raw statement returned by Fio. PII (counterparty names, account
  # numbers, payment messages), so the importer additionally requires Rails.env.local?.
  config.x.fio.debug_raw = ENV["FIO_DEBUG_RAW"].to_s.strip.downcase.in?(%w[1 true yes])
end
