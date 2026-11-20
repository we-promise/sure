module Security::Provided
  extend ActiveSupport::Concern

  SecurityInfoMissingError = Class.new(StandardError)

  # Needs no API key, so it can stand in for an enabled provider that can't be built
  KEYLESS_FALLBACK_PROVIDER = "yahoo_finance"

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

    # The registry key of a provider instance, e.g. "twelve_data".
    def provider_key_for(provider_instance)
      provider_instance.class.name.demodulize.underscore
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

  # `include_classification` widens the refetch gate below so a security that
  # already has a name and a logo -- which is most of them -- can still be
  # asked for its classification.
  #
  # It defaults to FALSE because the unbounded shape is the importers' cadence,
  # not any single call. `Account::MarketDataImporter` and `MarketDataImporter`
  # walk every security on every sync, so a widened gate that never closes
  # costs one provider request per security per sync, indefinitely. The gate
  # closing is what bounds that, and the importers opt in on that basis.
  #
  # The third caller, `HoldingsController#sync_prices`, is a POST behind
  # `require_holding_write_permission!` -- a user asking for one holding's
  # prices, not a page view; `#show` makes no provider call at all. It keeps
  # the narrow gate because the user asked for prices, not for classification.
  #
  # `include_constituents` is the same opt-in for a fund's holdings, on the same
  # terms: it rides the same `fetch_security_info` call, and the importers pass
  # it because its gate closes after one successful answer.
  def import_provider_details(clear_cache: false, include_classification: false, include_constituents: false)
    # Read once: the default provider can change while the request is in
    # flight, and the stamps must name the provider that actually answered.
    provider = price_data_provider
    unless provider.present?
      Rails.logger.warn("No provider configured for Security.import_provider_details")
      return
    end

    # Price-provider metadata (name/website/logo). Skip the refetch only when we
    # already have a name plus a logo or website. This gate must be evaluated
    # before any brand-logo enrichment, otherwise setting logo_url first would
    # trip it and skip website_url backfill from providers that return links.
    has_metadata = self.name.present? && (self.logo_url.present? || self.website_url.present?)
    # A provider is asked for a classification only when it can give one and
    # nothing is known yet:
    # - `supplies_classification?` first: a provider with no sector to give
    #   never fills the columns below, so without it the gate never closes.
    # - No source: cash and crypto carry a `default` source, which no provider
    #   improves on. A sector alone does not close the gate, since it leaves
    #   the asset class unanswered.
    # - Not yet asked of this provider: an answer that holds nothing (a bond,
    #   an ETF with no sector) is stamped with the provider that gave it, so
    #   that provider is asked once. A failed answer is not stamped, so it is
    #   retried. The stamp is compared with the provider resolved now, so an
    #   assigned provider changing and the enabled default changing (for a
    #   security with no `price_provider`) both open the gate.
    provider_key = self.class.provider_key_for(provider)
    wants_classification = include_classification && provider.supplies_classification? &&
      !classification_locked? && classification_source.blank? &&
      (classification_fetched_at.nil? || classification_fetched_from != provider_key)

    # Keyed on the TIMESTAMP, not on whether constituents are present. Most
    # securities are not funds, so the provider returns nothing for them -- and a
    # presence-keyed gate would re-ask every one of those on every sync, for
    # ever. The timestamp is written whether or not anything came back, which is
    # what lets "never asked" be told from "asked, nothing there".
    #
    # Capability gates the ASK, not the stamp. Gating the stamp instead would
    # leave this flag true for ever under a provider that cannot answer, and it
    # is read below as a separate term that `has_metadata` cannot short-circuit,
    # so every security would be fetched on every sync. With the ask gated, a
    # nil stamp under an incapable provider is harmless, and the day a capable
    # one is configured the security is asked once and settles.
    #
    # The stamp names the provider that answered and is compared with the one
    # resolved now, as the classification stamp is, so a different provider
    # -- assigned, or the enabled default for a security with no
    # `price_provider` -- is asked once.
    #
    # A forced refresh (`clear_cache`) asks again too: a fund's holdings change
    # as it rebalances, and the stamp otherwise closes the gate for good.
    wants_constituents = include_constituents && provider.supplies_constituents? &&
      (clear_cache || constituents_fetched_at.nil? || constituents_fetched_from != provider_key)

    unless has_metadata && !wants_classification && !wants_constituents && !clear_cache
      response = provider.fetch_security_info(
        symbol: ticker,
        exchange_operating_mic: exchange_operating_mic
      )

      if response.success?
        # Before the lock: `with_lock` reloads the row, and `store_constituents`
        # compares the stamp under its own lock with the one this import read
        # before asking. Reloading first would make another import's set look
        # like this one's, and replace it.
        if wants_constituents
          begin
            store_constituents(response.data.constituents, provider)
          rescue => e
            # A write the pre-checks missed (an invalid byte sequence Postgres
            # refuses) must not cost the security its name and classification,
            # nor stop the sync's remaining securities.
            log_failed_constituents(provider, e)
          end
        end
        # `with_lock` re-reads the row, so precedence is checked against what
        # it holds now: a manual classification, a sector or a lock written
        # while the provider was answering is not overwritten.
        with_lock do
          # Only overwrite fields the provider actually returned, so providers that
          # don't support metadata (e.g. Alpha Vantage) won't blank existing values.
          attrs = {}
          attrs[:name]        = response.data.name    if response.data.name.present?
          attrs[:logo_url]    = response.data.logo_url if response.data.logo_url.present?
          attrs[:website_url] = response.data.links   if response.data.links.present?
          attrs.merge!(classification_attributes_from(response.data, classifies: provider.supplies_classification?))
          stored = attrs.empty? || update(attrs)
          # `update` runs the model's validations, and a row can hold a value
          # they now refuse (a legacy region, a ticker clash). Its answer is
          # stamped anyway, with the refusal logged for support: an unstamped
          # row is asked again on every sync, and each ask costs a provider
          # request. A lock set while the provider answered rejects the answer
          # instead, and closes the gate on its own.
          if wants_classification && !classification_locked?
            log_refused_classification(provider, errors.full_messages) unless stored
            update_columns(classification_fetched_at: Time.current, classification_fetched_from: provider_key)
          end
        end
      else
        Rails.logger.warn("Failed to fetch security info for #{ticker} from #{provider.class.name}: #{response.error.message}")
        DebugLogEntry.capture(
          category: "security_metadata_fetch",
          level: "warn",
          message: "Failed to get security info",
          source: self.class.name,
          provider: provider,
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

  # Replaces the fund's holdings wholesale rather than merging: a constituent
  # that has left the fund must leave the table with it, and a merge would leave
  # it behind for ever.
  #
  # The timestamp is written even when `list` is nil -- that is the whole point
  # of the gate above: "asked, nothing there" has to be distinguishable from
  # "never asked", and only a stamp can say so.
  #
  # The delete runs before that, so this must only ever be reached for a
  # provider that can actually answer. The caller gates the ask on
  # `supplies_constituents?`, and this guard is a second lock on the same door:
  # an incapable provider reaching here would wipe a stored set it was never in
  # a position to replace, and then stamp the emptiness as fact.
  #
  # A row the table would refuse is skipped and logged, not raised: one bad row
  # would roll the whole fund back unstamped and stop both market data
  # importers at this fund on every run.
  #
  # An answer that says nothing about the fund leaves the stored set and the
  # stamp alone, so the next sync asks again: a holdings block the provider's
  # parser could not read, or a non-empty list none of whose rows can be
  # stored.
  def store_constituents(list, provider = price_data_provider)
    return unless provider&.supplies_constituents?

    # An unreadable answer keeps the stored set, but is stamped like any
    # answer: unstamped, the fund would be fetched again on every sync, and
    # each fetch costs a provider request. One log entry says why.
    if list == Provider::SecurityConcept::UNREADABLE_CONSTITUENTS
      log_unreadable_constituents(provider)
      stamp_constituents(provider)
      return
    end

    rows, skipped = constituent_rows_from(list)

    if rows.empty? && Array(list).any?
      log_unreadable_constituents(provider, skipped: skipped.map(&:first).tally)
      stamp_constituents(provider)
      return
    end

    # One DELETE and one INSERT rather than a statement or two per holding: a
    # world tracker lists thousands, and this runs inside the account sync.
    # `constituent_rows_from` has already applied every rule the model and the
    # column would, so skipping validation here refuses nothing they would
    # accept. `Security::Constituent` has no callbacks for `delete_all` to skip.
    #
    # Securities are shared across families, so two syncs can replace one fund
    # at once. The row lock makes the second wait, where its DELETE would
    # otherwise miss the uncommitted rows and its INSERT break the unique
    # index. Under the lock it reads the stamp again: one written since this
    # import read it means the other import has stored its answer, and that
    # set stays. `lock!` is not used: it reloads, and would drop attributes a
    # failed `update` just left unsaved.
    replaced = transaction do
      stamp = self.class.where(id: id).lock.pick(:constituents_fetched_at)
      next false if stamp && stamp != constituents_fetched_at

      constituents.delete_all
      Security::Constituent.insert_all!(rows.map { |row| row.merge(security_id: id) }) if rows.any?
      stamp_constituents(provider)
      true
    end
    constituents.reset

    skipped.each { |reason, entry| log_skipped_constituent(reason, entry, provider) } if replaced
  end

  # Splits a provider list into rows the table will accept and [reason, entry]
  # pairs it would refuse. Tickers and exchange codes are stripped and
  # upcased, so `msft` and `MSFT` are one holding, and a holding is its ticker
  # on its exchange, as the unique index has it; the first occurrence is the
  # one kept.
  #
  # A weight is checked against the column as well as the model: `BigDecimal`
  # parses "NaN" and "Infinity" without raising, and a value the model accepts
  # can still overflow `numeric(9,6)`, so either would have raised out of the
  # transaction just as an invalid row did.
  def constituent_rows_from(list)
    seen = Set.new
    rows = []
    skipped = []
    weight_scale = constituent_weight_scale
    weight_limit = constituent_weight_limit

    Array(list).each do |entry|
      unless entry.is_a?(Hash)
        skipped << [ "malformed_entry", entry ]
        next
      end

      raw_ticker = entry[:ticker] || entry["ticker"]
      ticker = raw_ticker.is_a?(String) ? raw_ticker.strip.upcase : ""
      raw_exchange = entry[:exchange] || entry["exchange"]
      exchange = raw_exchange.is_a?(String) ? raw_exchange.strip.upcase.presence : nil
      name = (entry[:name] || entry["name"]).to_s.strip.presence
      raw_weight = entry[:weight] || entry["weight"]
      weight = begin
        raw_weight.present? ? BigDecimal(raw_weight.to_s) : nil
      rescue ArgumentError, TypeError
        :non_numeric
      end
      weight = :non_numeric if weight.is_a?(BigDecimal) && !weight.finite?

      # Postgres refuses a NUL in a text column, as it would the rows below.
      reason = if !raw_ticker.nil? && !raw_ticker.is_a?(String) then "non_string_ticker"
      elsif ticker.blank? then "blank_ticker"
      elsif ticker.include?("\0") || name&.include?("\0") || exchange&.include?("\0") then "nul_character"
      elsif weight == :non_numeric then "non_numeric_weight"
      elsif weight&.negative? then "negative_weight"
      elsif weight && weight.round(weight_scale) >= weight_limit then "out_of_range_weight"
      elsif seen.include?([ ticker, exchange ]) then "duplicate_ticker"
      end

      if reason
        skipped << [ reason, entry ]
      else
        seen << [ ticker, exchange ]
        rows << { ticker: ticker, exchange: exchange, name: name, weight: weight }
      end
    end

    [ rows, skipped ]
  end

  # The bound `numeric(precision, scale)` holds, read from the column so the two
  # cannot drift: Postgres rounds to the scale first, so 999.9999995 overflows.
  def constituent_weight_limit
    column = Security::Constituent.columns_hash["weight"]
    BigDecimal(10)**(column.precision - column.scale)
  end

  # The scale half of `weight`'s numeric(precision, scale) bound, read from the
  # column like `constituent_weight_limit` so the two cannot drift apart.
  def constituent_weight_scale
    Security::Constituent.columns_hash["weight"].scale
  end

  # Records a fund holding the provider reported in a form that cannot be
  # stored, so a skip stays traceable: the reason, the holding's ticker, and its
  # shape. The metadata runs through `without_nul` for the same jsonb reason.
  def log_skipped_constituent(reason, entry, provider = price_data_provider)
    DebugLogEntry.capture(
      category: "security_holdings",
      level: "warn",
      message: "Skipped a fund holding the provider reported in a form that cannot be stored",
      source: "Security#store_constituents",
      provider: provider,
      # Without NULs: the metadata column is jsonb, which refuses them as the
      # constituents table does, and the entry is logged because it is malformed.
      metadata: without_nul(
        security_id: id,
        security_ticker: ticker,
        ticker: entry.is_a?(Hash) ? (entry[:ticker] || entry["ticker"]) : nil,
        reason: reason,
        entry: entry.is_a?(Hash) ? entry.to_h : entry
      )
    )
  end

  # Records an answer whose holdings could not be read, so a fund whose stored
  # set did not change stays traceable. `skipped` counts the refused entries by
  # reason when every one was refused, in one entry rather than one per row.
  def log_unreadable_constituents(provider, skipped: nil)
    DebugLogEntry.capture(
      category: "security_holdings",
      level: "warn",
      message: "Kept a fund's stored holdings: the provider's holdings could not be read",
      source: "Security#store_constituents",
      provider: provider,
      metadata: { security_id: id, security_ticker: ticker, skipped: skipped }.compact
    )
  end

  def log_failed_constituents(provider, error)
    DebugLogEntry.capture(
      category: "security_holdings",
      level: "error",
      message: "Failed to store a fund's holdings",
      source: "Security#store_constituents",
      provider: provider,
      metadata: { security_id: id, security_ticker: ticker, error_class: error.class.name, error: error.message }
    )
  end

  def stamp_constituents(provider)
    update_columns(constituents_fetched_at: Time.current,
                   constituents_fetched_from: self.class.provider_key_for(provider))
  end

  # Postgres jsonb and the constituents table both refuse NUL bytes, so a
  # malformed entry carrying one cannot be logged or stored as-is. Strip them
  # recursively through strings, hashes, and arrays.
  def without_nul(value)
    case value
    when String then value.delete("\0")
    when Hash then value.to_h { |key, inner| [ without_nul(key), without_nul(inner) ] }
    when Array then value.map { |inner| without_nul(inner) }
    else value
    end
  end
  private :store_constituents, :constituent_rows_from, :constituent_weight_limit,
    :constituent_weight_scale, :log_skipped_constituent, :log_unreadable_constituents, :without_nul,
    :log_failed_constituents, :stamp_constituents

  # A provider's type says what the wrapper is, not what it holds. "Common
  # stock" is an equity whatever else is true of it, so it maps. An ETF or a
  # fund does NOT: a bond ETF and an equity ETF are the same wrapper around
  # different asset classes, and answering "equity" for both would fill an
  # allocation with a figure no one can justify. Those are left unclassified
  # until something can see what they hold.
  ASSET_CLASS_FROM_PROVIDER_KIND = {
    "common stock" => [ "equity", "stock" ],
    "equity" => [ "equity", "stock" ],
    "stock" => [ "equity", "stock" ]
  }.freeze

  # A fund's own type does name its wrapper, so the sub-class is known. Its
  # asset class comes from its category when that names one (commodity,
  # money market), and otherwise from what it holds (`fund_weights`), but
  # only when one class holds at least FUND_DOMINANT_WEIGHT percent of the
  # fund. A 60/40 fund has no single answer, so it gets none rather than a
  # misleading one.
  FUND_SUB_CLASS_FROM_PROVIDER_KIND = {
    "etf" => "etf",
    "fund" => "mutual_fund",
    "mutual fund" => "mutual_fund"
  }.freeze

  FUND_DOMINANT_WEIGHT = 90

  # Percentage points a provider's fund breakdown may stray outside 0..100
  # before it is read as a short or leveraged position rather than rounding:
  # settlement and TBA rolls leave long-only funds a few percent short on cash.
  FUND_WEIGHT_TOLERANCE = 10

  # The provider is the second-weakest writer: it may fill what nothing has
  # answered, and may replace a `default`, but never a `manual` classification,
  # and never anything at all on a locked security. Only a provider that
  # classifies may claim the classification: an instrument type from one that
  # does not (Twelve Data) would stamp `provider` as the source and keep a
  # capable provider from ever being asked.
  def log_refused_classification(provider, messages)
    DebugLogEntry.capture(
      category: "security_metadata_fetch",
      level: "warn",
      message: "Security details refused by validation",
      source: self.class.name,
      provider: provider,
      metadata: { security_id: id, ticker: ticker, errors: messages }
    )
  end
  private :log_refused_classification

  def classification_attributes_from(data, classifies: true)
    return {} if classification_locked?

    kind = data.kind.to_s.downcase
    fund_sub_class = FUND_SUB_CLASS_FROM_PROVIDER_KIND[kind]
    weights = fund_sub_class ? (data.fund_weights || {}) : {}

    mapped_class, mapped_sub_class = ASSET_CLASS_FROM_PROVIDER_KIND[kind]
    if fund_sub_class
      mapped_class = fund_asset_class(weights)
      mapped_sub_class = fund_sub_class
    end
    # World_Regions and Sector_Weights describe only the fund's equity
    # sleeve, so they speak for the fund only when equity is what it holds.
    # A bond fund with a 1% US-equity sliver is not a North American fund.
    equity_fund = fund_sub_class && mapped_class == "equity"

    attrs = {}
    # Free text with no other writer, so "already set" is the only guard it
    # needs -- a value a user corrected is not re-stated here.
    provided_sector = data.sector.presence || (dominant_fund_weight(weights[:equity_sector]) if equity_fund)
    attrs[:sector] = provided_sector if provided_sector.present? && sector.blank?
    attrs[:industry] = data.industry if data.industry.present? && industry.blank?

    return attrs unless classifies && classification_source.in?([ nil, "default" ])

    if mapped_class.present?
      attrs[:asset_class] = mapped_class
      attrs[:asset_sub_class] = mapped_sub_class
      attrs[:classification_source] = "provider"
    elsif fund_sub_class && asset_sub_class.blank?
      # The wrapper is known even when its holdings settle no class (a 60/40
      # fund, a Yahoo-priced ETF with no breakdown). The sub-class alone is
      # not a classification, so the source stays unclaimed, but it keeps the
      # listing country from setting the fund's region.
      attrs[:asset_sub_class] = fund_sub_class
    end

    # A stock keeps the region its listing country gives it: a provider's
    # issuer country is the country of incorporation, which moves Accenture
    # or Medtronic (Irish-domiciled, US-run) to Europe.
    #
    # A fund's listing or domicile country (Ireland, Luxembourg) says nothing
    # about what it holds, so a fund's region is the dominant
    # region of its equity holdings, or none: a world ETF, a bond fund or a
    # commodity fund has its listing region cleared. The provider replaces
    # the region only while it is blank or still the one the listing
    # implies, so a different region someone set by hand stays. One set by
    # hand to the listing's own region cannot be told from the derived one,
    # since nothing records where a region came from, and is replaced.
    if fund_sub_class &&
        (region.blank? || region == Security::REGIONS.dig(country_code.to_s.upcase, "region"))
      attrs[:region] = (dominant_fund_weight(weights[:equity_region]) if equity_fund)
    end

    attrs
  end

  # Nil when the fund is leveraged or inverse, or its weights are not plain
  # long holdings (a short position, or a class above 100%): its holdings
  # then say little about its exposure. Cash alone never decides the class:
  # a commodity-futures ETF holds mostly T-bills as collateral. A money
  # market fund is classified from its category instead.
  def fund_asset_class(weights)
    return nil if weights[:leveraged_or_inverse]

    classes = weights[:asset_class] || {}
    tolerance = FUND_WEIGHT_TOLERANCE
    return nil if classes.values.any? { |percent| percent < -tolerance || percent > 100 + tolerance }

    weights[:category_asset_class].presence || dominant_fund_weight(classes.except("liquidity"))
  end
  private :fund_asset_class

  def dominant_fund_weight(weights)
    return nil if weights.blank?

    bucket, percent = weights.max_by { |_, value| value }
    bucket if percent >= FUND_DOMINANT_WEIGHT
  end
  private :dominant_fund_weight
end
