class ScalableCapitalItem::Securities
  PENDING_RESOLUTION = "resolution_pending"
  SCALABLE_MARKET_DATA = Provider::ScalableCapitalMarketData::KEY

  def initialize(item, snapshots)
    @mapping = item.security_ids.dup
    @securities = Security.where(id: @mapping.values).index_by(&:id)
    @pending = @mapping.keys.select { |isin| pending_resolution?(@securities[@mapping[isin]]) }
    @failed_lookups = Set.new
    @scalable_market_data = Setting.enabled_securities_providers.include?(SCALABLE_MARKET_DATA) && item.market_data_portfolio_id.present?

    imported_isins = snapshots.flat_map do |snapshot|
      [ *snapshot.fetch(:positions), *snapshot.fetch(:entries) ].filter_map { |entry| entry[:isin] }
    end
    isins = @pending | imported_isins.reject { |isin| @securities.key?(@mapping[isin]) }
    @listings = isins.index_with { |isin| best_listing(isin) }
  end

  attr_reader :mapping

  def resolve_pending!
    # A previously imported trade may no longer appear in the incremental feed.
    @pending.each { |isin| resolve(isin, nil) }
  end

  def resolve(isin, name)
    cached = @securities[@mapping[isin]]
    return cached if cached && !pending_resolution?(cached)

    listing = @listings[isin]
    security = listing ? resolve_listing(listing, name, cached) : resolve_offline(isin, name, cached)
    @mapping[isin] = security.id
    @securities[security.id] = security
  end

  private

    def resolve_listing(listing, name, placeholder)
      identity = { ticker: listing.ticker.upcase, exchange_operating_mic: listing.exchange_operating_mic }
      attributes = { name: listing.name.presence || name || placeholder&.name,
                     country_code: listing.country_code, price_provider: listing.price_provider }
      security = Security.find_or_initialize_by(identity)
      if placeholder && security.new_record?
        # Preserve the existing holding and trade references when no listing row exists.
        placeholder.update!(identity.merge(attributes, offline: false, offline_reason: nil))
        return placeholder
      end

      security.update!(attributes) if security.new_record?
      if placeholder
        Security::Merger.new(from: placeholder, into: security).merge!(
          condition: ->(source) { pending_resolution?(source) }
        )
      end
      if pending_resolution?(security)
        security.with_lock do
          next unless pending_resolution?(security)

          security.update!(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil,
                           price_provider: security.price_provider.presence || listing.price_provider)
        end
      end
      security
    end

    def resolve_offline(isin, name, cached)
      security = cached || Security.find_or_create_by!(ticker: isin, exchange_operating_mic: nil) do |record|
        record.name = name
        record.offline = !scalable_price_available?(isin)
        record.price_provider = SCALABLE_MARKET_DATA unless record.offline?
      end
      if pending_resolution?(security) && scalable_price_available?(isin)
        security.update!(price_provider: SCALABLE_MARKET_DATA, offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
        return security
      end
      if @failed_lookups.include?(isin)
        security.update!(offline_reason: PENDING_RESOLUTION) if security.offline? && security.offline_reason.blank?
      elsif pending_resolution?(security)
        security.update!(offline_reason: nil)
      end
      security
    end

    def pending_resolution?(security)
      security&.offline? && security.offline_reason == PENDING_RESOLUTION
    end

    def best_listing(isin)
      # The sync holds the CLI lock and already has the exact Scalable ISIN.
      options = @scalable_market_data ? { exclude_providers: [ SCALABLE_MARKET_DATA ] } : {}
      Security.search_provider(isin, country_code: "DE", technical_failure: ->(_provider) { @failed_lookups.add(isin) }, **options)
        .select { |listing| listing.search_isin&.casecmp?(isin) && listing.ticker.present? && listing.exchange_operating_mic.present? }
        .min_by do |listing|
          [ listing.search_currency == "EUR" ? 0 : 1, listing.country_code == "DE" ? 0 : 1,
            listing.exchange_operating_mic == "XETR" ? 0 : 1 ]
        end
    end

    def scalable_price_available?(isin)
      @scalable_market_data && Provider::ScalableCapitalMarketData.supports_symbol?(isin)
    end
end
