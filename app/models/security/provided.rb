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
    # Returns nil if the provider is disabled in settings or not configured.
    def provider_for(name)
      return nil if name.blank?
      return nil unless Setting.enabled_securities_providers.include?(name.to_s)
      Provider::Registry.for_concept(:securities).get_provider(name.to_sym)
    rescue Provider::Registry::Error
      nil
    end

    # Cache duration for search results (avoids burning through provider rate limits)
    SEARCH_CACHE_TTL = 5.minutes

    # Maximum number of results returned to the combobox dropdown
    MAX_SEARCH_RESULTS = 30

    # Per-provider timeout so one slow provider can't stall the entire search
    PROVIDER_SEARCH_TIMEOUT = 8.seconds

    def search_provider(symbol, country_code: nil, exchange_operating_mic: nil)
      return [] if symbol.blank?

      active_providers = providers.compact
      return [] if active_providers.empty?

      params = {
        country_code: country_code,
        exchange_operating_mic: exchange_operating_mic
      }.compact_blank

      # Query all providers concurrently so the total wall time is max(provider
      # latencies) instead of sum. Each future runs in the concurrent-ruby thread
      # pool, keeping Puma threads unblocked during individual provider sleeps.
      futures = active_providers.map do |prov|
        Concurrent::Promises.future(prov) do |provider|
          fetch_provider_results(provider, symbol, params)
        end
      end

      # Collect results from each future individually with a shared deadline.
      # Unlike zip (which is all-or-nothing), this keeps results from fast
      # providers even when a slow one times out.
      deadline = Time.current + PROVIDER_SEARCH_TIMEOUT
      results_array = futures.map do |future|
        remaining = [ (deadline - Time.current), 0 ].max
        future.value(remaining)
      end

      all_results = []
      seen_keys = Set.new

      results_array.each_with_index do |provider_results, idx|
        next if provider_results.nil?

        provider_key = provider_key_for(active_providers[idx])

        provider_results.each do |ps|
          # Dedup key includes provider so the same ticker on the same exchange can
          # appear once per provider — the user picks which provider's price feed
          # they want and that choice is stored in price_provider.
          dedup_key = "#{ps[:symbol]}|#{ps[:exchange_operating_mic]}|#{provider_key}".upcase
          next if seen_keys.include?(dedup_key)
          seen_keys.add(dedup_key)

          security = Security.new(
            ticker: ps[:symbol],
            name: ps[:name],
            logo_url: ps[:logo_url],
            exchange_operating_mic: ps[:exchange_operating_mic],
            country_code: ps[:country_code],
            search_currency: ps[:currency],
            price_provider: provider_key
          )
          all_results << security
        end
      end

      if all_results.empty? && active_providers.any?
        Rails.logger.warn("Security search: all #{active_providers.size} providers returned no results for '#{symbol}'")
      end

      rank_search_results(all_results, symbol, country_code).first(MAX_SEARCH_RESULTS)
    end

    private
      def provider_key_for(provider_instance)
        provider_instance.class.name.demodulize.underscore
      end

      # Fetches (or reads from cache) search results for a single provider.
      # Designed to run inside a Concurrent::Promises.future.
      def fetch_provider_results(prov, symbol, params)
        provider_key = provider_key_for(prov)
        cache_key = "security_search:#{provider_key}:#{symbol.upcase}:#{Digest::SHA256.hexdigest(params.sort_by { |k, _| k }.to_json)}"

        Rails.cache.fetch(cache_key, expires_in: SEARCH_CACHE_TTL, skip_nil: true) do
          response = prov.search_securities(symbol, **params)
          next nil unless response.success?

          response.data.map do |ps|
            { symbol: ps.symbol, name: ps.name, logo_url: ps.logo_url,
              exchange_operating_mic: ps.exchange_operating_mic, country_code: ps.country_code,
              currency: ps.respond_to?(:currency) ? ps.currency : nil }
          end
        end
      rescue => e
        Rails.logger.warn("Security search failed for #{provider_key}: #{e.message}")
        nil
      end

      # Scores and sorts search results so the most relevant matches appear first.
      # Scoring criteria (lower = better):
      #   0: exact ticker match
      #   1: ticker starts with query
      #   2: name contains query
      #   3: everything else
      # Within the same relevance tier, user's country is preferred.
      def rank_search_results(results, symbol, country_code)
        query = symbol.upcase
        user_country = country_code&.upcase

        results.sort_by do |s|
          ticker_up = s.ticker.upcase
          relevance = if ticker_up == query
            0
          elsif ticker_up.start_with?(query)
            1
          elsif s.name&.upcase&.include?(query)
            2
          else
            3
          end

          country_match = (user_country.present? && s.country_code&.upcase == user_country) ? 0 : 1

          [ relevance, country_match, ticker_up ]
        end
      end
  end

  # Public method: resolves the provider for this specific security.
  # Uses the security's assigned price_provider if available and configured.
  # Falls back to the first enabled provider only when no specific provider
  # was ever assigned. When an assigned provider becomes unavailable, returns
  # nil so the security is skipped rather than queried against an incompatible
  # provider (e.g. MFAPI scheme codes sent to TwelveData).
  def price_data_provider
    if price_provider.present?
      assigned = self.class.provider_for(price_provider)
      return assigned if assigned.present?
      return nil # assigned provider is unavailable — don't silently fall back
    end
    self.class.providers.first
  end

  # Returns the health status of this security's provider link.
  # Delegates to price_data_provider to avoid duplicating provider lookup logic.
  def provider_status
    resolved = price_data_provider

    # Had a specific provider assigned but it's now unavailable
    return :provider_unavailable if resolved.nil? && price_provider.present?

    return :offline if offline?
    return :no_provider if resolved.nil?
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
      # Only overwrite fields the provider actually returned, so providers that
      # don't support metadata (e.g. Alpha Vantage) won't blank existing values.
      attrs = {}
      attrs[:name]        = response.data.name    if response.data.name.present?
      attrs[:logo_url]    = response.data.logo_url if response.data.logo_url.present?
      attrs[:website_url] = response.data.links   if response.data.links.present?
      update(attrs) if attrs.any?
    else
      Rails.logger.warn("Failed to fetch security info for #{ticker} from #{price_data_provider.class.name}: #{response.error.message}")
      DebugLogEntry.capture(
        category: "security_metadata_fetch",
        level: "warn",
        message: "Failed to get security info",
        source: self.class.name,
        provider: price_data_provider,
        metadata: {
          security_id: self.id,
          ticker: ticker,
          provider_error: response.error.message
        }
      )
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
