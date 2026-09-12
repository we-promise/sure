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

    # Preserve the native price currency. Account/family views convert when aggregating
    # so manual calculated holdings stay consistent with provider snapshots.
    Security::Price.new(
      security_id: security_id,
      date: price.date,
      price: price.price,
      currency: price.currency
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

      # Bulk-load all DB prices for all securities in one query, grouped by security_id.
      # Explicit currency order keeps same-priority ties deterministic across syncs.
      db_prices_by_security_id = Security::Price
        .where(security_id: security_ids, date: account.start_date..Date.current)
        .order(:security_id, :date, :currency)
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
        # Exclude income entries (interest/dividend) — they are non-trading
        # events with qty=0 and their zero price would clobber the security's
        # market price on that date in the ForwardCalculator, producing a
        # zero-amount holding.  Use qty (the same heuristic as
        # Balance::BaseCalculator) rather than price to avoid blocking
        # non-income zero-price trades such as Questrade journal transfers.
        trade_prices = (trades_by_security_id[security.id] || [])
          .reject { |t| t.entryable.qty == 0 }
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

        # Low priority prices from holdings (if applicable).
        # Skip neutralized manual rows (qty/amount zeroed for cost-basis recovery).
        # Sold-out calculated rows stay — their prices are still valid market data.
        holding_prices = if use_holdings
          (holdings_by_security_id[security.id] || [])
            .reject { |holding| holding.qty.zero? && !holding.calculated? }
            .map do |holding|
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

        # Prefer the security's most common observed currency (usually its listing /
        # provider currency) when account currency is absent among tied prices.
        preferred_security_currency = preferred_currency_for(all_prices)

        # Index by date for O(1) lookup in get_price instead of O(N) linear scan.
        # When priorities tie: account currency → security's preferred currency →
        # alphabetical, so native-currency selection cannot flip between syncs.
        prices_by_date = all_prices.group_by { |p| p.price.date }
          .transform_values { |ps| pick_preferred_price(ps, preferred_security_currency:) }
        prices_by_date_and_source = all_prices.group_by { |p| [ p.price.date, p.source ] }
          .transform_values { |ps| pick_preferred_price(ps, preferred_security_currency:) }

        @security_cache[security.id] = {
          security: security,
          prices_by_date: prices_by_date,
          prices_by_date_and_source: prices_by_date_and_source
        }
      end
    end

    def preferred_currency_for(price_with_priorities)
      counts = Hash.new(0)
      price_with_priorities.each { |candidate| counts[candidate.price.currency.to_s] += 1 }
      return nil if counts.empty?

      # Highest frequency, then alphabetical for a stable secondary key.
      counts.min_by { |currency, count| [ -count, currency ] }.first
    end

    def pick_preferred_price(price_with_priorities, preferred_security_currency: nil)
      price_with_priorities.min_by do |candidate|
        currency = candidate.price.currency.to_s
        [
          candidate.priority,
          currency == account.currency ? 0 : 1,
          preferred_security_currency && currency == preferred_security_currency ? 0 : 1,
          currency
        ]
      end
    end
end
