# Resolves every exchange-listed security referenced by the stored payloads
# before TradeRepublicAccount::Processor opens its database transaction.
# Unknown listings trigger Security.search_provider (HTTP with a multi-second
# deadline); doing that inside the transaction would hold it open for the
# duration of every lookup.
class TradeRepublicAccount::SecurityPrefetcher
  include TradeRepublicAccount::DataHelpers

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  # Returns { [symbol, mic] => Security } for the account processors.
  def prefetch
    listings.each do |(symbol, mic), name|
      cached_exchange_security(symbol, mic, name)
    rescue StandardError => e
      Rails.logger.warn("TradeRepublicAccount::SecurityPrefetcher - #{symbol}/#{mic}: #{e.message}")
    end

    exchange_securities
  end

  private

    def listings
      position_listings.merge(trade_listings) { |_key, position_name, _trade_name| position_name }
    end

    def position_listings
      Array(@trade_republic_account.raw_positions_payload).each_with_object({}) do |position, map|
        next unless position.is_a?(Hash)

        position = position.with_indifferent_access
        add_listing(map, position[:isin], position[:name], position[:symbol], position[:exchange_slug])
      end
    end

    def trade_listings
      return {} unless @trade_republic_account.portfolio?

      Array(@trade_republic_account.raw_timeline_payload).each_with_object({}) do |event, map|
        next unless event.is_a?(Hash)
        next unless Provider::TradeRepublicClient.requires_trade_detail?(event)
        next unless importable_timeline_event?(event)

        event = event.with_indifferent_access
        detail = event[:detail]
        next unless detail.is_a?(Hash)

        add_listing(map, detail[:isin], detail[:name] || event[:title], detail[:symbol], detail[:exchange_slug])
      end
    end

    def add_listing(map, isin, name, symbol, exchange_slug)
      return if isin.blank?

      listing = exchange_listing_for(isin.to_s, symbol: symbol, exchange_slug: exchange_slug)
      map[listing] ||= name if listing
    end
end
