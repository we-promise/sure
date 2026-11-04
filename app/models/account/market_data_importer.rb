class Account::MarketDataImporter
  attr_reader :account

  def initialize(account)
    @account = account
  end

  # Prices are imported first so their currencies are known when deciding
  # which exchange rate pairs the account needs.
  def import_all
    import_security_prices
    import_exchange_rates
  end

  def import_exchange_rates
    return unless needs_exchange_rates?
    return unless ExchangeRate.provider

    pair_dates = {}
    family_currency = account.family.primary_currency_code

    # 1. ENTRY-BASED PAIRS – currencies that differ from the account currency.
    # Each is also fetched against the family currency: transfer matching derives
    # cross rates through it and does not chain entry -> account -> family rates.
    account.entries
           .where.not(currency: account.currency)
           .group(:currency)
           .minimum(:date)
           .each do |source_currency, date|
      [ account.currency, family_currency ].uniq.each do |target_currency|
        next if target_currency == source_currency

        key = [ source_currency, target_currency ]
        pair_dates[key] = [ pair_dates[key], date ].compact.min
      end
    end

    # 2. ACCOUNT-BASED PAIR – convert the account currency to the family currency (if different)
    if foreign_account?
      key = [ account.currency, family_currency ]
      pair_dates[key] = [ pair_dates[key], account.start_date ].compact.min
    end

    # 3. SECURITY PRICE PAIRS – holdings convert each security price into the
    # account currency, so every foreign price currency needs rates from the
    # first date a price for that security is required.
    security_price_currency_start_dates.each do |source_currency, date|
      key = [ source_currency, account.currency ]
      pair_dates[key] = [ pair_dates[key], date ].compact.min
    end

    pair_dates.each do |(source, target), start_date|
      ExchangeRate.import_provider_rates(
        from: source,
        to: target,
        start_date: start_date,
        end_date: Date.current
      )
    end
  end

  def import_security_prices
    return unless Security.provider

    return if price_windows.empty?

    securities = Security.online.where(id: price_windows.keys).index_by(&:id)

    price_windows.each do |security_id, window|
      security = securities[security_id]
      next unless security

      security.import_provider_prices(start_date: window.start_date, end_date: window.end_date)
      security.import_provider_details
    end
  end

  private
    def price_windows
      @price_windows ||= Security::Price::ImportWindows.new(account).to_h
    end

    def security_ids
      price_windows.keys
    end

    def first_required_price_dates
      price_windows.transform_values(&:start_date)
    end

    # Earliest required date per price currency that differs from the account currency.
    # Securities are shared across families, so a price's own date is not a bound.
    # Currencies whose prices all predate the account's first required date are skipped.
    def security_price_currency_start_dates
      @security_price_currency_start_dates ||= begin
        latest_foreign_price_dates = Security::Price.where(security_id: security_ids)
                                                    .where.not(currency: account.currency)
                                                    .group(:security_id, :currency)
                                                    .maximum(:date)

        latest_foreign_price_dates.each_with_object({}) do |((security_id, currency), latest_date), dates|
          start_date = first_required_price_dates[security_id]
          next if latest_date < start_date

          dates[currency] = [ dates[currency], start_date ].compact.min
        end
      end
    end

    def needs_exchange_rates?
      has_multi_currency_entries? || foreign_account? || security_price_currency_start_dates.any?
    end

    def has_multi_currency_entries?
      account.entries.where.not(currency: account.currency).exists?
    end

    def foreign_account?
      return false if account.family.nil?
      account.currency != account.family.primary_currency_code
    end
end
