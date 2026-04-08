module Security::Provided
  extend ActiveSupport::Concern

  SecurityInfoMissingError = Class.new(StandardError)

  class_methods do
    # Returns all enabled and configured securities providers
    def providers
      Setting.enabled_securities_providers.filter_map do |name|
        Provider::Registry.for_concept(:securities).get_provider(name.to_sym)
      rescue Provider::Registry::Error
        nil
      end
    end

    # Backward compat: first enabled provider
    def provider
      providers.first
    end

    # Get a specific provider by key name (e.g., "finnhub", "twelve_data")
    def provider_for(name)
      return nil if name.blank?
      Provider::Registry.for_concept(:securities).get_provider(name.to_sym)
    rescue Provider::Registry::Error
      nil
    end

    # Cache duration for search results (avoids burning through provider rate limits)
    SEARCH_CACHE_TTL = 5.minutes

    def search_provider(symbol, country_code: nil, exchange_operating_mic: nil)
      return [] if symbol.blank?

      all_results = []
      seen_keys = Set.new

      providers.each do |prov|
        next if prov.nil?

        provider_key = provider_key_for(prov)

        params = {
          country_code: country_code,
          exchange_operating_mic: exchange_operating_mic
        }.compact_blank

        # Cache search results per provider+query to avoid repeated API calls
        cache_key = "security_search:#{provider_key}:#{symbol.upcase}:#{params.sort}"
        provider_results = Rails.cache.fetch(cache_key, expires_in: SEARCH_CACHE_TTL) do
          response = prov.search_securities(symbol, **params)
          next nil unless response.success?

          response.data.map do |ps|
            { symbol: ps.symbol, name: ps.name, logo_url: ps.logo_url,
              exchange_operating_mic: ps.exchange_operating_mic, country_code: ps.country_code }
          end
        end

        next if provider_results.nil?

        provider_results.each do |ps|
          dedup_key = "#{ps[:symbol]}|#{ps[:exchange_operating_mic]}".upcase
          next if seen_keys.include?(dedup_key)
          seen_keys.add(dedup_key)

          security = Security.new(
            ticker: ps[:symbol],
            name: ps[:name],
            logo_url: ps[:logo_url],
            exchange_operating_mic: ps[:exchange_operating_mic],
            country_code: ps[:country_code],
            price_provider: provider_key
          )
          all_results << security
        end
      end

      # Sort results to prioritize user's country if provided
      if country_code.present?
        user_country = country_code.upcase
        all_results.sort_by do |s|
          [
            s.country_code&.upcase == user_country ? 0 : 1, # User's country first
            s.ticker.upcase == symbol.upcase ? 0 : 1        # Exact ticker match second
          ]
        end
      else
        all_results
      end
    end

    private
      def provider_key_for(provider_instance)
        provider_instance.class.name.demodulize.underscore
      end
  end

  # Public method: resolves the provider for this specific security.
  # Uses the security's assigned price_provider if available and configured,
  # otherwise falls back to the first available enabled provider.
  def price_data_provider
    if price_provider.present?
      assigned = self.class.provider_for(price_provider)
      return assigned if assigned.present?
    end
    self.class.providers.first
  end

  # Returns the health status of this security's provider link
  def provider_status
    return :ok if offline?
    return :no_provider if price_data_provider.nil?

    if price_provider.present?
      assigned = self.class.provider_for(price_provider)
      return :provider_unavailable if assigned.nil?
    end

    return :stale if failed_fetch_count.to_i > 0
    :ok
  end

  def find_or_fetch_price(date: Date.current, cache: true)
    price = prices.find_by(date: date)

    return price if price.present?

    # Don't fetch prices for offline securities (e.g., custom tickers from SimpleFIN)
    return nil if offline?

    # Make sure we have a data provider before fetching
    return nil unless price_data_provider.present?
    response = price_data_provider.fetch_security_price(
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
    unless price_data_provider.present?
      Rails.logger.warn("No provider configured for Security.import_provider_details")
      return
    end

    if self.name.present? && (self.logo_url.present? || self.website_url.present?) && !clear_cache
      return
    end

    response = price_data_provider.fetch_security_info(
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
      Rails.logger.warn("Failed to fetch security info for #{ticker} from #{price_data_provider.class.name}: #{response.error.message}")
      Sentry.capture_exception(SecurityInfoMissingError.new("Failed to get security info"), level: :warning) do |scope|
        scope.set_tags(security_id: self.id)
        scope.set_context("security", { id: self.id, provider_error: response.error.message })
      end
    end
  end

  def import_provider_prices(start_date:, end_date:, clear_cache: false)
    unless price_data_provider.present?
      Rails.logger.warn("No provider configured for Security.import_provider_prices")
      return 0
    end

    importer = Security::Price::Importer.new(
      security: self,
      security_provider: price_data_provider,
      start_date: start_date,
      end_date: end_date,
      clear_cache: clear_cache
    )
    [ importer.import_provider_prices, importer.provider_error ]
  end
end
