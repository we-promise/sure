module Security::Provided
  extend ActiveSupport::Concern

  SecurityInfoMissingError = Class.new(StandardError)

  class_methods do
    def provider
      provider = ENV["SECURITIES_PROVIDER"].presence || Setting.securities_provider
      registry = Provider::Registry.for_concept(:securities)
      registry.get_provider(provider.to_sym)
    end

    def search_provider(symbol, country_code: nil, exchange_operating_mic: nil)
      return [] if provider.nil? || symbol.blank?

      params = {
        country_code: country_code,
        exchange_operating_mic: exchange_operating_mic
      }.compact_blank

      response = provider.search_securities(symbol, **params)

      if response.success?
        securities = response.data.map do |provider_security|
          # Need to map to domain model so Combobox can display via to_combobox_option
          Security.new(
            ticker: provider_security.symbol,
            name: provider_security.name,
            logo_url: provider_security.logo_url,
            exchange_operating_mic: provider_security.exchange_operating_mic,
            country_code: provider_security.country_code
          )
        end

        # Sort results to prioritize user's country if provided
        if country_code.present?
          user_country = country_code.upcase
          securities.sort_by do |s|
            [
              s.country_code&.upcase == user_country ? 0 : 1, # User's country first
              s.ticker.upcase == symbol.upcase ? 0 : 1        # Exact ticker match second
            ]
          end
        else
          securities
        end
      else
        []
      end
    end
  end

  def find_or_fetch_price(date: Date.current, cache: true)
    price = prices.find_by(date: date)

    return price if price.present?

    # Don't fetch prices for offline securities (e.g., custom tickers from SimpleFIN)
    return nil if offline?

    # Make sure we have a data provider before fetching
    return nil unless provider.present?
    response = provider.fetch_security_price(
      symbol: ticker,
      exchange_operating_mic: exchange_operating_mic,
      date: date
    )

    return nil unless response.success? # Provider error

    price = response.data
    Security::Price.find_or_create_by!(
      security_id: self.id,
      date: price.date,
      price: price.price,
      currency: price.currency
    ) if cache
    price
  end

  def import_provider_details(clear_cache: false)
    unless provider.present?
      Rails.logger.warn("No provider configured for Security.import_provider_details")
      return
    end

    if self.name.present? && (self.logo_url.present? || self.website_url.present?) && !clear_cache
      return
    end

    response = provider.fetch_security_info(
      symbol: ticker,
      exchange_operating_mic: exchange_operating_mic
    )

    if response.success?
      update(
        name: response.data.name,
        logo_url: response.data.logo_url,
        website_url: response.data.links
      )
    else
      Rails.logger.warn("Failed to fetch security info for #{ticker} from #{provider.class.name}: #{response.error.message}")
      Sentry.capture_exception(SecurityInfoMissingError.new("Failed to get security info"), level: :warning) do |scope|
        scope.set_tags(security_id: self.id)
        scope.set_context("security", { id: self.id, provider_error: response.error.message })
      end
    end
  end

  def import_provider_prices(start_date:, end_date:, clear_cache: false)
    unless provider.present?
      Rails.logger.warn("No provider configured for Security.import_provider_prices")
      return 0
    end

    Security::Price::Importer.new(
      security: self,
      security_provider: provider,
      start_date: start_date,
      end_date: end_date,
      clear_cache: clear_cache
    ).import_provider_prices
  end

  private
    def provider
      self.class.provider
    end
end
