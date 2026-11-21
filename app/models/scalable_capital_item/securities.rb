class ScalableCapitalItem::Securities
  def initialize(item, snapshots)
    @mapping = item.security_ids.dup
    @securities = Security.where(id: @mapping.values).index_by(&:id)
    @listings = {}
    snapshots.each do |snapshot|
      [ *snapshot.fetch(:positions), *snapshot.fetch(:entries) ].each do |entry|
        isin = entry[:isin]
        next if isin.nil? || @securities.key?(@mapping[isin]) || @listings.key?(isin)

        @listings[isin] = best_listing(isin)
      end
    end
  end

  attr_reader :mapping

  def resolve(isin, name)
    cached = @securities[@mapping[isin]]
    return cached if cached

    listing = @listings[isin]
    security = if listing
      Security.find_or_create_by!(ticker: listing.ticker.upcase, exchange_operating_mic: listing.exchange_operating_mic) do |record|
        record.name = listing.name.presence || name
        record.country_code = listing.country_code
        record.price_provider = listing.price_provider
      end
    else
      Security.find_or_create_by!(ticker: isin, exchange_operating_mic: nil) do |record|
        record.offline = true
        record.name = name
      end
    end
    @mapping[isin] = security.id
    @securities[security.id] = security
  end

  private

    def best_listing(isin)
      Security.search_provider(isin, country_code: "DE")
        .select { |listing| listing.search_isin&.casecmp?(isin) && listing.ticker.present? && listing.exchange_operating_mic.present? }
        .min_by do |listing|
          [ listing.search_currency == "EUR" ? 0 : 1, listing.country_code == "DE" ? 0 : 1,
            listing.exchange_operating_mic == "XETR" ? 0 : 1 ]
        end
    end
end
