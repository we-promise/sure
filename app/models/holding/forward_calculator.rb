class Holding::ForwardCalculator
  attr_reader :account

  def initialize(account, security_ids: nil)
    @account = account
    @security_ids = security_ids
    # Track buy lots per security so cost basis can be converted into the holding's
    # native price currency (not forced into account.currency).
    @cost_basis_tracker = Hash.new { |h, k| h[k] = [] }
    # Memoize cost basis by [security_id, currency, lot_count] so days without new
    # buys are O(1), and memoize FX rates by [from, to, date] across lots/days.
    @cost_basis_memo = {}
    @fx_rate_memo = {}
  end

  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      account.start_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        update_cost_basis_tracker(trades)
        next_portfolio = transform_portfolio(current_portfolio, trades, direction: :forward)
        holdings.concat(build_holdings(next_portfolio, date))
        current_portfolio = next_portfolio
      end

      Holding.gapfill(holdings)
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, security_ids: @security_ids)
    end

    def empty_portfolio
      securities = portfolio_cache.get_securities
      securities.each_with_object({}) { |security, hash| hash[security.id] = 0 }
    end

    def generate_starting_portfolio
      empty_portfolio
    end

    def transform_portfolio(previous_portfolio, trade_entries, direction: :forward)
      new_quantities = previous_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        qty_change = trade.qty
        qty_change = qty_change * -1 if direction == :reverse
        new_quantities[security_id] = (new_quantities[security_id] || 0) + qty_change
      end

      new_quantities
    end

    def build_holdings(portfolio, date, price_source: nil)
      portfolio.map do |security_id, qty|
        next if @security_ids && !@security_ids.include?(security_id)

        price = portfolio_cache.get_price(security_id, date, source: price_source)

        if price.nil?
          next
        end

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id, price.currency)
        )
      end.compact
    end

    # Updates cost basis tracker with buy trades (qty > 0)
    # Uses weighted average cost method
    def update_cost_basis_tracker(trade_entries)
      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        next unless trade.qty > 0 # Only track buys

        @cost_basis_tracker[trade.security_id] << {
          qty: trade.qty,
          price: trade.price,
          currency: trade.currency,
          date: trade_entry.date
        }
      end
    end

    # Returns the current cost basis for a security in the holding currency, or nil if no buys recorded
    # or a cross-currency buy cannot be converted.
    def cost_basis_for(security_id, currency)
      buys = @cost_basis_tracker[security_id]
      return nil if buys.empty?

      memo_key = [ security_id, currency, buys.size ]
      return @cost_basis_memo[memo_key] if @cost_basis_memo.key?(memo_key)

      @cost_basis_memo[memo_key] = weighted_average_cost(buys, currency)
    end

    def weighted_average_cost(buys, currency)
      total_qty = buys.sum { |buy| buy[:qty] }
      return nil if total_qty.zero?

      total_cost = BigDecimal("0")

      buys.each do |buy|
        converted_price = convert_buy_price(buy, currency)
        return nil if converted_price.nil?

        total_cost += converted_price * buy[:qty]
      end

      total_cost / total_qty
    end

    def convert_buy_price(buy, currency)
      return buy[:price] if buy[:currency] == currency

      rate = fx_rate(from: buy[:currency], to: currency, date: buy[:date])
      # Match Money#exchange_to: absent or non-positive rates are unusable
      # (ExchangeRate does not enforce positivity at the DB layer).
      return nil unless rate&.positive?

      buy[:price] * rate
    end

    def fx_rate(from:, to:, date:)
      key = [ from, to, date ]
      return @fx_rate_memo[key] if @fx_rate_memo.key?(key)

      @fx_rate_memo[key] = ExchangeRate.find_or_fetch_rate(from: from, to: to, date: date)&.rate
    end
end
