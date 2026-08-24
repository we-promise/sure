# Relabels mis-tagged Warsaw (XWAR / legacy WAR) security_prices from USD → PLN.
#
# Before Provider::Eodhd mapped Warsaw, search-cache expiry caused PLN closes to be
# persisted as USD (#3128). Numeric prices stay the same; only the currency label
# is corrected. When a PLN row already exists for the same (security, date), the
# USD duplicate is deleted to satisfy the unique index.
#
# Optionally upgrades legacy WAR MICs to XWAR and schedules account syncs so
# calculated holdings revalue with the corrected FX.
class Security::WarsawPriceCurrencyBackfill
  WARSAW_MICS = %w[XWAR WAR].freeze
  FROM_CURRENCY = "USD"
  TO_CURRENCY = "PLN"

  Result = Data.define(
    :securities_scanned,
    :mics_canonicalized,
    :prices_relabeled,
    :prices_deleted,
    :accounts_queued_for_sync,
    :dry_run
  )

  def initialize(dry_run: false, sync_accounts: true)
    @dry_run = dry_run
    @sync_accounts = sync_accounts
  end

  def call
    securities_scanned = 0
    mics_canonicalized = 0
    prices_relabeled = 0
    prices_deleted = 0
    touched_security_ids = []

    warsaw_securities.find_each do |security|
      securities_scanned += 1

      mic_changed = canonicalize_mic!(security)
      mics_canonicalized += 1 if mic_changed

      relabeled, deleted = fix_prices_for!(security)
      prices_relabeled += relabeled
      prices_deleted += deleted
      if mic_changed || relabeled.positive? || deleted.positive?
        touched_security_ids << security.id
      end
    end

    accounts_queued = enqueue_account_syncs!(touched_security_ids.uniq)

    Result.new(
      securities_scanned: securities_scanned,
      mics_canonicalized: mics_canonicalized,
      prices_relabeled: prices_relabeled,
      prices_deleted: prices_deleted,
      accounts_queued_for_sync: accounts_queued,
      dry_run: dry_run
    )
  end

  private
    attr_reader :dry_run, :sync_accounts

    def warsaw_securities
      Security.where("UPPER(exchange_operating_mic) IN (?)", WARSAW_MICS)
    end

    def canonicalize_mic!(security)
      return false unless security.exchange_operating_mic.to_s.upcase == "WAR"

      existing_canonical = Security
        .where("UPPER(ticker) = ?", security.ticker.to_s.upcase)
        .where("UPPER(exchange_operating_mic) = ?", "XWAR")
        .where.not(id: security.id)
        .first

      return false if existing_canonical # leave merge to securities:deduplicate

      unless dry_run
        security.update_columns(exchange_operating_mic: "XWAR", updated_at: Time.current)
      end

      true
    end

    def fix_prices_for!(security)
      pln_dates = security.prices.where(currency: TO_CURRENCY).pluck(:date).to_set
      usd_prices = security.prices.where(currency: FROM_CURRENCY)
      usd_rows = usd_prices.pluck(:id, :date)

      to_delete_ids = []
      to_relabel_ids = []
      usd_rows.each do |id, date|
        if pln_dates.include?(date)
          to_delete_ids << id
        else
          to_relabel_ids << id
        end
      end

      unless dry_run
        Security::Price.where(id: to_delete_ids).delete_all if to_delete_ids.any?
        if to_relabel_ids.any?
          Security::Price.where(id: to_relabel_ids).update_all(
            currency: TO_CURRENCY,
            updated_at: Time.current
          )
        end
      end

      [ to_relabel_ids.size, to_delete_ids.size ]
    end

    def enqueue_account_syncs!(touched_security_ids)
      return 0 unless sync_accounts

      security_ids = security_ids_for_account_sync(touched_security_ids)
      return 0 if security_ids.empty?

      account_ids = Holding.where(security_id: security_ids).distinct.pluck(:account_id)
      return 0 if account_ids.empty?

      unless dry_run
        Account.where(id: account_ids).find_each(&:sync_later)
      end

      account_ids.size
    end

    # Without a DDL transaction, a failed migration may relabel prices and then
    # abort before sync. On retry those rows are already PLN and won't look
    # "touched", so also requeue holdings for Warsaw securities that no longer
    # have mis-tagged USD prices.
    def security_ids_for_account_sync(touched_security_ids)
      usd_prices_for_holding = Security::Price
        .where(currency: FROM_CURRENCY)
        .where(Security::Price.arel_table[:security_id].eq(Holding.arel_table[:security_id]))

      corrected_without_usd = Holding
        .where(security_id: warsaw_securities.select(:id))
        .where.not(usd_prices_for_holding.arel.exists)
        .distinct
        .pluck(:security_id)

      (touched_security_ids + corrected_without_usd).uniq
    end
end
