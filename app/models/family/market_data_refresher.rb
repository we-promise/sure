# Downloads again the security prices and exchange rates a family's accounts
# use, overwriting the stored values. Both are shared by every family on the
# instance, so they are refreshed in place rather than deleted. Each security
# and currency pair is fetched once, over the widest window any account needs.
class Family::MarketDataRefresher
  def initialize(family)
    @family = family
  end

  # Prices come first: their currencies decide which exchange rates are needed.
  def refresh
    refresh_security_prices
    refresh_exchange_rates
  end

  private
    attr_reader :family

    def importers
      @importers ||= family.accounts.map { |account| Account::MarketDataImporter.new(account) }
    end

    def refresh_security_prices
      return unless Security.provider

      windows = importers.each_with_object({}) do |importer, merged|
        importer.price_windows.each do |security_id, window|
          merged[security_id] = window.merge(merged[security_id])
        end
      end
      return if windows.empty?

      Security.online.where(id: windows.keys).find_each do |security|
        window = windows[security.id]
        security.import_provider_prices(start_date: window.start_date, end_date: window.end_date, clear_cache: true)
        security.import_provider_details
      rescue => e
        report_failure(e, provider: security.price_data_provider, security_id: security.id)
      end
    end

    def refresh_exchange_rates
      provider = ExchangeRate.provider
      return unless provider

      pair_dates = importers.each_with_object({}) do |importer, merged|
        importer.exchange_rate_pair_dates.each do |pair, start_date|
          merged[pair] = [ merged[pair], start_date ].compact.min
        end
      end

      pair_dates.each do |(from, to), start_date|
        ExchangeRate.import_provider_rates(from: from, to: to, start_date: start_date, end_date: Date.current, clear_cache: true)
      rescue => e
        report_failure(e, provider: provider, from_currency: from, to_currency: to)
      end
    end

    def report_failure(error, provider:, **metadata)
      Sentry.capture_exception(error)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Could not refresh market data: #{error.class}: #{error.message}",
        source: self.class.name,
        family: family,
        provider: provider,
        metadata: metadata
      )
    end
end
