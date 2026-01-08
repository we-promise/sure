class Holding::ForwardCalculator
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      account.start_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        next_portfolio = transform_portfolio(current_portfolio, trades, direction: :forward)
        holdings += build_holdings(next_portfolio, date)
        current_portfolio = next_portfolio
      end

      # Inclure aussi la première date où qty=0 pour chaque security (fermeture de position)
      valid_holdings = []
      holdings.group_by(&:security_id).each do |security_id, sec_holdings|
        sorted = sec_holdings.sort_by(&:date)
        prev_qty = nil
        sorted.each do |h|
          if h.qty.to_f > 0 && h.amount.to_f > 0
            valid_holdings << h
          elsif h.qty.to_f == 0 && prev_qty && prev_qty > 0
            # On ajoute la première date où qty=0 après une séquence >0
            valid_holdings << h
          end
          prev_qty = h.qty.to_f
        end
      end
      Holding.gapfill(valid_holdings)   
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account)
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
        price = portfolio_cache.get_price(security_id, date, source: price_source)

        if price.nil?
          next
        end

        Holding.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price
        )
      end.compact
    end
end
