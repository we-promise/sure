class Holding::PortfolioCache
  attr_reader :account, :use_holdings

  class SecurityNotFound < StandardError
    def initialize(security_id, account_id)
      super("Security id=#{security_id} not found in portfolio cache for account #{account_id}.  This should not happen unless securities were preloaded incorrectly.")
    end
  end

  def initialize(account, use_holdings: false, security_ids: nil)
    @account = account
    @use_holdings = use_holdings
    @security_ids = security_ids
    load_prices
  end

  def get_trades(date: nil)
    if date.blank?
      trades
    else
      trades_by_date[date]&.dup || []
    end
  end

  def get_price(security_id, date, source: nil)
    security = @security_cache[security_id]
    raise SecurityNotFound.new(security_id, account.id) unless security

    price_with_priority = if source.present?
      security[:prices_by_date_and_source][[ date, source ]]
    else
      security[:prices_by_date][date]
    end

    return nil unless price_with_priority

    price = price_with_priority.price
    return nil unless price

    price_money = Money.new(price.price, price.currency)

    begin
      converted_amount = price_money.exchange_to(account.currency).amount
    rescue Money::ConversionError
      converted_amount = price.price
    end

    Security::Price.new(
      security_id: security_id,
      date: price.date,
      price: converted_amount,
      currency: account.currency
    )
  end

  def get_securities
    @security_cache.map { |_, v| v[:security] }
  end

  private
    PriceWithPriority = Data.define(:price, :priority, :source)

    def trades
      @trades ||= account.entries.includes(entryable: :security).trades.chronological.to_a
    end

    def trades_by_date
      @trades_by_date ||= trades.group_by(&:date)
    end

    def trades_by_security_id
      @trades_by_security_id ||= trades.group_by { |t| t.entryable.security_id }
    end

    def holdings
      @holdings ||= account.holdings.chronological.to_a
    end

    def holdings_by_security_id
      @holdings_by_security_id ||= holdings.group_by(&:security_id)
    end

    def collect_unique_securities
      ids = trades_by_security_id.keys
      ids |= holdings_by_security_id.keys if use_holdings
      ids &= @security_ids if @security_ids

      Security.where(id: ids).to_a
    end

    # Loads all known prices for all securities in the account with priority based on source:
    # 1 - DB or provider prices
    # 2 - Trade prices
    # 3 - Holding prices
    def load_prices
      @security_cache = {}
      securities = collect_unique_securities

      Rails.logger.info "Preloading #{securities.size} securities for account #{account.id}"

      security_ids = securities.map(&:id)

      # Bulk-load all DB prices for all securities in one query, grouped by security_id
      db_prices_by_security_id = Security::Price
        .where(security_id: security_ids, date: account.start_date..Date.current)
        .group_by(&:security_id)

      securities.each do |security|
        Rails.logger.info "Loading security: ID=#{security.id} Ticker=#{security.ticker}"

        # High priority prices from DB (synced from provider)
        db_prices = (db_prices_by_security_id[security.id] || []).map do |price|
          PriceWithPriority.new(
            price: price,
            priority: 1,
            source: "db"
          )
        end

        # Medium priority prices from trades
        trade_prices = (trades_by_security_id[security.id] || [])
          .map do |trade|
            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: trade.entryable.price,
                currency: trade.entryable.currency,
                date: trade.date
              ),
              priority: 2,
              source: "trade"
            )
          end

        # Low priority prices from holdings (if applicable)
        holding_prices = if use_holdings
          (holdings_by_security_id[security.id] || []).map do |holding|
            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: holding.price,
                currency: holding.currency,
                date: holding.date
              ),
              priority: 3,
              source: "holding"
            )
          end
        else
          []
        end

        all_prices = db_prices + trade_prices + holding_prices

        # Index by date for O(1) lookup in get_price instead of O(N) linear scan
        prices_by_date = all_prices.group_by { |p| p.price.date }
          .transform_values { |ps| ps.min_by(&:priority) }
        prices_by_date_and_source = all_prices.group_by { |p| [ p.price.date, p.source ] }
          .transform_values { |ps| ps.min_by(&:priority) }

        @security_cache[security.id] = {
          security: security,
          prices_by_date: prices_by_date,
          prices_by_date_and_source: prices_by_date_and_source
        }
      end
    end
end
