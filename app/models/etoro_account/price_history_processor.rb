# Stores eToro's daily closes (see EtoroItem::PriceHistoryImporter) as the
# prices of offline securities no price provider covers, and marks those
# securities so that Sure's health checks, which go on looking for a provider
# for them, do not delete eToro's prices when they find none.
class EtoroAccount::PriceHistoryProcessor
  OFFLINE_REASON = "etoro_prices".freeze

  # The offline securities eToro's prices may go on: those the resolver could
  # not find with a provider, those a provider stopped finding, and those
  # eToro already prices. Any other reason is a user's or another provider's.
  # Of the first two, only one with no prices yet: a security a provider
  # stopped finding keeps the prices it had, and eToro's would overwrite
  # them and, on release, take them away.
  ADOPTABLE_OFFLINE_REASONS = [ nil, "health_check_failed", OFFLINE_REASON ].freeze

  BATCH_SIZE = 500

  # Rows written, closes left out for want of an exchange rate, and the
  # first day written.
  Result = Data.define(:written, :missing_rates, :first_date)

  class << self
    # A security online is a price provider's, as one eToro prices is once a
    # health check finds it with the provider.
    def priceable?(security)
      return false if security.nil? || security.cash? || security.price_provider.present?

      return false unless security.offline? && ADOPTABLE_OFFLINE_REASONS.include?(security.offline_reason)

      claimed_or_unpriced?(security)
    end

    # Asks the database whether eToro claimed it, since a sync can claim a
    # security another copy of the record was loaded before.
    def claimed_or_unpriced?(security)
      security.offline_reason == OFFLINE_REASON ||
        !security.prices.exists? ||
        Security.where(id: security.id, offline_reason: OFFLINE_REASON).exists?
    end

    # Hands securities eToro no longer prices back to Sure, a price provider
    # or the health checks, without the prices eToro gave them: those are
    # for this account's holdings alone. The accounts that hold or trade one
    # were valued at them, so they are synced again, apart from the one
    # `syncing` now, which its own sync values again. Takes the instruments'
    # price histories (see EtoroItem::PriceHistoryImporter).
    def release(histories, syncing: nil)
      histories = Array(histories).select { |history| history.is_a?(Hash) && history["security_id"].present? }
      return if histories.empty?

      emptied = Security::Price.transaction do
        Security.where(id: histories.map { |history| history["security_id"] }.uniq, offline_reason: OFFLINE_REASON)
          .update_all(offline_reason: nil, updated_at: Time.current)
        histories.select { |history| etoro_prices(history).delete_all.positive? }.map { |history| history["security_id"] }.uniq
      end
      sync_holders(emptied, except: syncing)
    end

    private

      # The prices eToro gave a security: in the currency eToro quotes it in,
      # from the first day it wrote one.
      def etoro_prices(history)
        return Security::Price.none if history["currency"].blank? || history["written_from"].blank?

        Security::Price.where(security_id: history["security_id"], currency: history["currency"], date: Date.iso8601(history["written_from"])..)
      end

      def sync_holders(security_ids, except:)
        return if security_ids.empty?

        traded = Trade.joins(:entry).where(security_id: security_ids).distinct.pluck("entries.account_id")
        held = Holding.where(security_id: security_ids).distinct.pluck(:account_id)
        Account.where(id: (traded + held).uniq).where.not(id: except&.id).where.not(status: "pending_deletion").find_each(&:sync_later)
      end
  end

  def initialize(etoro_account)
    @etoro_account = etoro_account
    @rates_requested_from = {}
  end

  # Writes one security's prices, given by date in `currency`, and claims the
  # security with them. A day whose price has no exchange rate into the
  # account's currency is left out: the holdings would read the price as if
  # it were in the account's currency. A replacement that stores prices also
  # drops the security's prices in other currencies; one that stores none
  # keeps them until it can. Writes nothing, and returns nil, once the
  # security is no longer one eToro may price.
  def process(security, currency:, closes:, replace: false)
    dates = convertible_dates(currency, closes.keys)
    rows = closes.slice(*dates).map do |date, price|
      { security_id: security.id, date: date, price: price, currency: currency, provisional: false }
    end

    written = Security::Price.transaction do
      next false unless lock_priceable(security.id, claim: rows.any?)

      Security::Price.where(security_id: security.id).where.not(currency: currency).delete_all if replace && rows.any?
      rows.each_slice(BATCH_SIZE) { |batch| Security::Price.upsert_all(batch, unique_by: %i[security_id date currency]) }
      true
    end
    return unless written

    Result.new(written: rows.size, missing_rates: closes.size - rows.size, first_date: rows.map { |row| row[:date] }.min)
  end

  private

    # Locks the security for the write while eToro may still price it,
    # offline with no provider: a health check can bring it online, or a user
    # give it a provider, during the sync, and its prices are the provider's
    # then. Prices claim it, so that a failed health check neither counts
    # against it nor deletes them. The lock is the one an update of the
    # security takes, which leaves alone the rows that refer to it, such as
    # the holdings an account sync stores meanwhile.
    def lock_priceable(security_id, claim:)
      security = Security.lock("FOR NO KEY UPDATE").find_by(id: security_id, offline: true, price_provider: nil, offline_reason: ADOPTABLE_OFFLINE_REASONS)
      return false if security.nil? || security.cash? || !self.class.claimed_or_unpriced?(security)

      security.update_columns(offline_reason: OFFLINE_REASON, updated_at: Time.current) if claim && security.offline_reason != OFFLINE_REASON
      true
    end

    def account_currency
      @etoro_account.current_account&.currency || @etoro_account.currency
    end

    # The dates a stored rate converts a `currency` price on, after asking
    # the exchange rate provider for the rates missing.
    def convertible_dates(currency, dates)
      return dates if dates.empty? || currency == account_currency

      covered = rated_dates(currency, dates)
      return covered if covered.size == dates.size

      import_rates(currency, dates.min)
      rated_dates(currency, dates)
    end

    # Dates with a rate on the day or on one of the days before it that
    # ExchangeRate.find_or_fetch_rate falls back to.
    def rated_dates(currency, dates)
      lookback = ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS
      rate_days = ExchangeRate
        .where(from_currency: currency, to_currency: account_currency, date: (dates.min - lookback)..dates.max)
        .order(:date)
        .pluck(:date)

      dates.select do |date|
        index = rate_days.bsearch_index { |day| day > date } || rate_days.size
        index.positive? && rate_days[index - 1] >= date - lookback
      end
    end

    # Asked once a run for each currency, unless a later price needs rates
    # from further back.
    def import_rates(currency, from)
      return if @rates_requested_from[currency] && @rates_requested_from[currency] <= from

      @rates_requested_from[currency] = from
      ExchangeRate.import_provider_rates(from: currency, to: account_currency, start_date: from, end_date: Date.current)
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroAccount::PriceHistoryProcessor - Could not import #{currency}/#{account_currency} exchange rates: #{e.class} - #{e.message}",
        source: "etoro",
        provider_key: "etoro",
        family: @etoro_account.etoro_item.family,
        account_provider: @etoro_account.account_provider,
        metadata: { currency: currency, from: from.iso8601, etoro_account_id: @etoro_account.id }
      )
    end
end
