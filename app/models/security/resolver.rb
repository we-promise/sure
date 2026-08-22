class Security::Resolver
  def initialize(symbol, exchange_operating_mic: nil, country_code: nil, price_provider: nil)
    @symbol = validate_symbol!(symbol)
    @exchange_operating_mic = exchange_operating_mic
    @country_code = country_code
    @price_provider = validated_price_provider(price_provider)
  end

  # Attempts several paths to resolve a security:
  # 1. Exact match in DB
  # 2. Search provider for an exact match
  # 3. Search provider for close match, ranked by relevance
  # 4. Create offline security if no match is found in either DB or provider
  def resolve
    return nil if symbol.blank?

    exact_match_from_db ||
      exact_match_from_provider ||
      close_match_from_provider ||
      offline_security(reason: provider_search_technical_failure? ? "resolution_pending" : nil)
  end

  private
    attr_reader :symbol, :exchange_operating_mic, :country_code, :price_provider

    def validate_symbol!(symbol)
      raise ArgumentError, "Symbol is required and cannot be blank" if symbol.blank?
      symbol.strip.upcase
    end

    # Only accept price_provider values that are known and currently enabled.
    # Prevents tampered combobox values from persisting invalid provider names.
    def validated_price_provider(value)
      return nil if value.blank?
      return nil unless Security.valid_price_providers.include?(value.to_s)
      return nil unless Setting.enabled_securities_providers.include?(value.to_s)
      value.to_s
    end

    # reason: nil means "provider search ran successfully and genuinely found
    # no match" — the pre-existing, generic offline fallback. A non-nil reason
    # (currently only "resolution_pending", see provider_search_technical_failure?)
    # means the search itself failed technically (rate limit/timeout/error),
    # so we don't yet know whether the security exists — a future retry
    # (e.g. the next daily import run) should attempt resolution again rather
    # than treating this as a confirmed non-match.
    def offline_security(reason: nil)
      security = Security.find_or_initialize_by(
        ticker: symbol,
        exchange_operating_mic: exchange_operating_mic,
      )

      security.assign_attributes(
        country_code: country_code,
        offline: true # This tells us that we shouldn't try to fetch prices later
      )
      # Don't clobber a more specific existing reason (e.g. "provider_disabled",
      # "health_check_failed") with "resolution_pending" — only write a new
      # reason when the record doesn't already have a more specific one.
      security.offline_reason = reason if reason.present? && security.offline_reason.blank?

      security.save!

      if reason == "resolution_pending"
        DebugLogEntry.capture(
          category: "security_resolution",
          level: "warn",
          message: "Could not resolve security: provider search failed technically (not a confirmed no-match)",
          source: self.class.name,
          provider_key: provider_search_technical_failure_keys.first,
          metadata: {
            security_id: security.id,
            ticker: symbol,
            exchange_operating_mic: exchange_operating_mic,
            country_code: country_code,
            failed_providers: provider_search_technical_failure_keys
          }
        )
      end

      security
    end

    def exact_match_from_db
      security = Security.find_by(
        {
          ticker: symbol,
          exchange_operating_mic: exchange_operating_mic,
          country_code: country_code.presence
        }.compact
      )

      return nil unless security

      # A "resolution_pending" record means the last provider search failed
      # technically (rate limit/timeout), not that the security is a
      # confirmed no-match. Skip the DB fast path so this resolution attempt
      # actually retries the provider instead of returning the same stale
      # offline record forever.
      return nil if security.offline? && security.offline_reason == "resolution_pending"

      # When the caller provides an explicit provider (e.g. user selected from
      # search results), honor that choice. Automated syncs (Plaid, SimpleFIN)
      # pass price_provider: nil and will not overwrite.
      if price_provider.present? && security.price_provider != price_provider
        security.update!(price_provider: price_provider)
      end

      reactivate_if_provider_available!(security)

      security
    end

    # If provided a ticker + exchange (and optionally, a country code), we can find exact matches
    def exact_match_from_provider
      # Without an exchange, we can never know if we have an exact match
      return nil unless exchange_operating_mic.present?

      match = provider_search_result.find do |s|
        ticker_matches = s.ticker&.upcase.to_s == symbol.upcase.to_s
        exchange_matches = s.exchange_operating_mic&.upcase.to_s == exchange_operating_mic.upcase.to_s

        if country_code && exchange_operating_mic
          ticker_matches && exchange_matches && country_matches?(s.country_code)
        else
          ticker_matches && exchange_matches
        end
      end

      return nil unless match

      find_or_create_provider_match!(match)
    end

    def close_match_from_provider
      filtered_candidates = provider_search_result

      # If a country code is specified, we MUST find a match with the same code
      # — but nil candidate country is treated as a wildcard (e.g. crypto from
      # Binance, which isn't tied to a jurisdiction).
      if country_code.present?
        filtered_candidates = filtered_candidates.select { |s| country_matches?(s.country_code) }
      end

      # 1. Prefer exact ticker matches (MSTR before MSTRX when searching for "MSTR")
      # 2. Prefer exact exchange_operating_mic matches (if one was provided)
      # 3. Rank by country relevance (lower index in the list is more relevant)
      # 4. Rank by exchange_operating_mic relevance (lower index in the list is more relevant)
      sorted_candidates = filtered_candidates.sort_by do |s|
        [
          s.ticker&.upcase.to_s == symbol.upcase.to_s ? 0 : 1,
          exchange_operating_mic.present? && s.exchange_operating_mic&.upcase.to_s == exchange_operating_mic.upcase.to_s ? 0 : 1,
          sorted_country_codes_by_relevance.index(s.country_code&.upcase.to_s) || sorted_country_codes_by_relevance.length,
          sorted_exchange_operating_mics_by_relevance.index(s.exchange_operating_mic&.upcase.to_s) || sorted_exchange_operating_mics_by_relevance.length
        ]
      end

      match = sorted_candidates.first

      return nil unless match

      find_or_create_provider_match!(match)
    end

    def find_or_create_provider_match!(match)
      security = Security.find_or_initialize_by(
        ticker: match.ticker,
        exchange_operating_mic: match.exchange_operating_mic,
      )

      security.country_code = match.country_code

      # Backfill the name straight from the search result — it's already
      # available here and doesn't depend on a later, separate
      # fetch_security_info/profile call succeeding. Some providers (e.g.
      # TwelveData on lower plan tiers) gate /profile entirely regardless of
      # symbol, so without this the name would never populate at all. Only
      # fills a blank name — never overwrites an existing (possibly
      # user-edited) one. Deliberately does NOT copy logo_url: that stays
      # sourced from fetch_security_info/Brandfetch so existing coverage for
      # those paths is unaffected.
      security.name = match.name if match.name.present? && security.name.blank?

      # Set provider when explicitly provided (user selection) or when the
      # record is new / has no provider yet. Automated syncs pass nil and
      # will not overwrite an existing choice.
      effective_provider = price_provider.presence ||
        (match.respond_to?(:price_provider) ? match.price_provider.presence : nil)

      if effective_provider.present?
        security.price_provider = effective_provider
      end

      security.save!

      reactivate_if_provider_available!(security)

      security
    end

    # If a security was marked offline, bring it back online whenever we have
    # a good reason to trust it can now be priced: either its provider was
    # temporarily disabled and is available again ("provider_disabled"), or
    # a provider search just found it again after a prior technical failure
    # ("resolution_pending"), or the caller explicitly passed a price_provider
    # — meaning the user picked this exact security+provider combination from
    # search results, which we trust the same way
    # HoldingsController#remap_security already does unconditionally.
    # Automated syncs (Plaid, SimpleFIN, imports) pass price_provider: nil and
    # won't trigger the explicit-selection path, so a security that went
    # offline for other reasons (e.g. "health_check_failed") stays offline
    # until a human explicitly re-confirms it.
    def reactivate_if_provider_available!(security)
      return unless security.offline?
      return unless price_provider.present? || %w[provider_disabled resolution_pending].include?(security.offline_reason)
      return unless security.price_data_provider.present?

      security.update!(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
    end

    # Candidate country matches when it equals the resolver's country OR when
    # the provider didn't report a country at all (e.g. crypto from Binance).
    # A nil candidate country is a legitimate "no jurisdiction" signal, not a
    # missing field, so we trust the user's provider + exchange pick.
    def country_matches?(candidate_country)
      return true if candidate_country.blank?
      candidate_country.upcase == country_code.upcase
    end

    def provider_search_result
      params = {
        exchange_operating_mic: exchange_operating_mic,
        country_code: country_code
      }.compact_blank

      @provider_search_result ||= Security.search_provider(
        symbol,
        technical_failure: ->(provider) { (@provider_search_technical_failure_keys ||= []) << provider.class.name.demodulize.underscore },
        **params
      )
    end

    # True when at least one enabled provider's search request errored/timed
    # out rather than answering with zero results. Only meaningful after
    # provider_search_result has run (close_match_from_provider always calls
    # it before resolve reaches the offline_security fallback).
    def provider_search_technical_failure?
      provider_search_technical_failure_keys.any?
    end

    def provider_search_technical_failure_keys
      @provider_search_technical_failure_keys || []
    end

    # Non-exhaustive list of common country codes for help in choosing "close" matches
    # User's country (if provided) is prioritized first, then sorted by market cap.
    def sorted_country_codes_by_relevance
      base_order = %w[US CN JP IN GB CA FR DE CH SA TW AU NL SE KR IE ES AE IT HK BR DK SG MX RU IL ID BE TH NO]

      # Prioritize user's country if provided
      if country_code.present?
        user_country = country_code.upcase
        [ user_country ] + (base_order - [ user_country ])
      else
        base_order
      end
    end

    # Non-exhaustive list of common exchange operating MICs for help in choosing "close" matches
    # This is very US-centric since our prices provider and user base is a majority US-based
    def sorted_exchange_operating_mics_by_relevance
      [
        "XNYS",  # New York Stock Exchange
        "XNAS",  # NASDAQ Stock Market
        "XOTC",  # OTC Markets Group (OTC Link)
        "OTCM",  # OTC Markets Group
        "OTCN",  # OTC Bulletin Board
        "OTCI",  # OTC International
        "OPRA",  # Options Price Reporting Authority
        "MEMX",  # Members Exchange
        "IEXA",  # IEX All-Market
        "IEXG",  # IEX Growth Market
        "EDXM",  # Cboe EDGX Exchange (Equities)
        "XCME",  # CME Group (Derivatives)
        "XCBT",  # Chicago Board of Trade
        "XPUS",  # Nasdaq PSX (U.S.)
        "XPSE",  # Nasdaq PHLX (U.S.)
        "XTRD",  # Nasdaq TRF (Trade Reporting Facility)
        "XTXD",  # FINRA TRACE (Trade Reporting)
        "XARC",  # NYSE Arca
        "XBOX",  # BOX Options Exchange
        "XBXO"  # BZX Options (Cboe)
      ]
    end
end
