module Security::Provided
  extend ActiveSupport::Concern

  SecurityInfoMissingError = Class.new(StandardError)

  # Needs no API key, so it can stand in for an enabled provider that can't be built
  KEYLESS_FALLBACK_PROVIDER = "yahoo_finance"

  # After a provider answers a details lookup, it isn't asked again for this
  # long, even when its answer left the security without a logo or website
  # (see import_provider_details).
  PROVIDER_DETAILS_RECHECK_INTERVAL = 7.days

  class_methods do
    # Returns all enabled and configured securities providers. When the first
    # enabled provider can't be built (e.g. no API key), the keyless Yahoo
    # Finance provider takes its place, unless that is already enabled. Only
    # the first position is substituted, so the substitute is always the
    # default for securities without an assigned provider.
    def providers
      names = Setting.enabled_securities_providers
      substitute = !names.include?(KEYLESS_FALLBACK_PROVIDER)

      names.each_with_index.filter_map do |name, index|
        provider = build_provider(name)
        next provider if provider || !substitute || index.positive?

        log_keyless_substitution(name)
        build_provider(KEYLESS_FALLBACK_PROVIDER)
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

    # technical_failure is an optional callable invoked once per provider that
    # errored/timed out (as opposed to answering with zero results). Callers
    # that need to distinguish "provider search technically failed" from
    # "provider search succeeded, nothing found" — e.g. Security::Resolver,
    # which must not treat a rate-limited/timed-out search as a confirmed
    # "no such security" — can pass a callback here instead of us changing
    # the return type for all callers (e.g. SecuritiesController just wants
    # the plain result array).
    def search_provider(symbol, country_code: nil, exchange_operating_mic: nil, technical_failure: nil)
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
        if provider_results.nil?
          technical_failure&.call(active_providers[idx])
          next
        end

        provider_key = provider_key_for(active_providers[idx])
        # The keyless substitute's key is never stored, so a security found
        # through it follows providers.first and moves to the configured
        # provider once that can be built. Its ticker is stored without Yahoo's
        # exchange suffix (SAP.DE becomes SAP on XETR), so that provider gets
        # the symbol it expects; Yahoo re-adds the suffix from the MIC.
        keyless_substitute = provider_key == KEYLESS_FALLBACK_PROVIDER && !Setting.enabled_securities_providers.include?(KEYLESS_FALLBACK_PROVIDER)
        provider_key = nil if keyless_substitute

        provider_results.each do |ps|
          ticker = keyless_substitute ? strip_yahoo_suffix(ps[:symbol], ps[:exchange_operating_mic]) : ps[:symbol]

          # Dedup key includes provider so the same ticker on the same exchange can
          # appear once per provider — the user picks which provider's price feed
          # they want and that choice is stored in price_provider.
          dedup_key = "#{ticker}|#{ps[:exchange_operating_mic]}|#{provider_key}".upcase
          next if seen_keys.include?(dedup_key)
          seen_keys.add(dedup_key)

          security = Security.new(
            ticker: ticker,
            name: ps[:name],
            logo_url: ps[:logo_url],
            exchange_operating_mic: ps[:exchange_operating_mic],
            country_code: ps[:country_code],
            search_currency: ps[:currency],
            search_isin: ps[:isin],
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
      def build_provider(name)
        Provider::Registry.for_concept(:securities).get_provider(name.to_sym)
      rescue Provider::Registry::Error
        nil
      end

      def strip_yahoo_suffix(symbol, exchange_operating_mic)
        suffix = Provider::YahooFinance::EXCHANGE_CONFIG.dig(exchange_operating_mic, :yahoo_suffix)
        suffix && symbol.end_with?(suffix) ? symbol.delete_suffix(suffix) : symbol
      end

      def log_keyless_substitution(name)
        @logged_keyless_substitutions ||= Concurrent::Set.new
        return unless @logged_keyless_substitutions.add?(name)

        Rails.logger.info("Securities provider #{name} can't be built; using #{KEYLESS_FALLBACK_PROVIDER} in its place")
      end

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
              currency: ps.respond_to?(:currency) ? ps.currency : nil,
              isin: ps.respond_to?(:isin) ? ps.isin : nil }
          end
        end
      rescue => e
        Rails.logger.warn("Security search failed for #{provider_key}: #{e.message}")
        nil
      end

      ISIN_FORMAT = /\A[A-Z]{2}[A-Z0-9]{9}\d\z/

      # True when the query is a well-formed ISIN: 2 letters, 9 alphanumerics and a
      # check digit (letters expand to two digits, then the Luhn check applies).
      def isin_query?(query)
        return false unless query.match?(ISIN_FORMAT)

        digits = query.chars.map { |c| c.match?(/\d/) ? c : (c.ord - 55).to_s }.join
        sum = digits.reverse.chars.each_with_index.sum do |c, i|
          n = c.to_i
          n *= 2 if i.odd?
          n > 9 ? n - 9 : n
        end
        (sum % 10).zero?
      end

      # Scores and sorts search results so the most relevant matches appear first.
      # Scoring criteria (lower = better):
      #  -1: the query is a valid ISIN and the result carries that exact ISIN
      #   0: exact ticker match
      #   1: ticker starts with query
      #   2: name contains query
      #   3: everything else
      # Within the same relevance tier, user's country is preferred.
      def rank_search_results(results, symbol, country_code)
        query = symbol.upcase
        user_country = country_code&.upcase
        isin_search = isin_query?(query)

        results.sort_by do |s|
          ticker_up = s.ticker.upcase
          relevance = if isin_search && s.search_isin.present? && s.search_isin.upcase == query
            -1
          elsif ticker_up == query
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
    provider = price_data_provider
    return nil unless provider.present?
    response = provider.fetch_security_price(
      symbol: ticker,
      exchange_operating_mic: exchange_operating_mic,
      date: date
    )

    unless response.success? # Provider error
      log_failed_price_fetch(response.error, provider)
      return nil
    end

    price = response.data
    Security::Price.find_or_create_by!(
      security_id: self.id,
      date: price.date,
      currency: price.currency
    ) { |record| record.price = price.price } if cache
    price
  end

  # Throttled so a page with many holdings missing today's price doesn't
  # flood the debug log with one entry per request — at most one per
  # security per day.
  def log_failed_price_fetch(error, provider = price_data_provider)
    cache_key = "security_price_fetch_log:#{id}:#{Date.current}"
    return unless Rails.cache.write(cache_key, true, expires_in: 24.hours, unless_exist: true)

    DebugLogEntry.capture(
      category: "security_price_fetch",
      level: "warn",
      message: "find_or_fetch_price failed",
      source: self.class.name,
      provider: provider,
      metadata: { security_id: id, ticker: ticker, provider_error: error&.message }
    )
  end
  private :log_failed_price_fetch

  def import_provider_details(clear_cache: false)
    unless price_data_provider.present?
      Rails.logger.warn("No provider configured for Security.import_provider_details")
      return
    end

    # Price-provider metadata (name/website/logo). Skip the refetch when we
    # already have a name plus a logo or website. This gate must be evaluated
    # before any brand-logo enrichment, otherwise setting logo_url first would
    # trip it and skip website_url backfill from providers that return links.
    #
    # Some answers can't close that gate: Yahoo Finance never returns a logo
    # and has no website for funds, so the importers would ask again on every
    # sync, one request per security. A successful answer is therefore also
    # remembered for PROVIDER_DETAILS_RECHECK_INTERVAL. A failed one isn't, so
    # it is retried on the next import.
    has_metadata = self.name.present? && (self.logo_url.present? || self.website_url.present?)
    unless (has_metadata || provider_details_recently_fetched?) && !clear_cache
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
        Rails.cache.write(provider_details_cache_key, true, expires_in: PROVIDER_DETAILS_RECHECK_INTERVAL)
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

    # Brand logo, sourced independently of the price provider, so a security
    # priced by a logo-less provider (e.g. MOEX/ISS) still gets a real logo.
    # Runs after metadata so it never short-circuits website_url backfill.
    import_brand_logo(clear_cache: clear_cache)
  end

  # Keyed by provider, so a security that moves to another provider asks it.
  def provider_details_cache_key
    "security_provider_details:#{id}:#{price_data_provider.class.name.demodulize.underscore}"
  end
  private :provider_details_cache_key

  def provider_details_recently_fetched?
    Rails.cache.exist?(provider_details_cache_key)
  end
  private :provider_details_recently_fetched?

  # Enriches the security with a brand logo from a dedicated logo provider
  # (T-Invest), independent of which provider supplies prices. No-op when the
  # logo is already set, for crypto (own logo path), or when no logo provider /
  # token is configured. Runs every details import while the logo is missing.
  def import_brand_logo(clear_cache: false)
    return if crypto?
    return if logo_url.present? && !clear_cache

    provider = brand_logo_provider
    return unless provider

    response = provider.fetch_security_info(symbol: ticker, exchange_operating_mic: exchange_operating_mic)
    return unless response.success? && response.data.logo_url.present?

    update(logo_url: response.data.logo_url)
  rescue => e
    DebugLogEntry.capture(
      category: "security_metadata_fetch",
      level: "warn",
      message: "Brand logo fetch failed",
      source: self.class.name,
      provider: brand_logo_provider,
      metadata: { security_id: self.id, ticker: ticker, provider_error: e.message }
    )
  end

  # The provider consulted for brand logos regardless of price provider. Returns
  # nil unless a T-Invest token is configured. Uses the class-level lookup so it
  # doesn't depend on (or interfere with) per-instance Registry expectations.
  def brand_logo_provider
    Provider::Registry.get_provider(:tinkoff_invest)
  rescue Provider::Registry::Error
    nil
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
