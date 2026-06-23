module Holding::Gapfillable
  extend ActiveSupport::Concern

  class_methods do
    def gapfill(holdings)
      filled_holdings = []

      holdings.group_by { |h| h.security_id }.each do |security_id, security_holdings|
        next if security_holdings.empty?

        sorted = security_holdings.sort_by(&:date)
        holdings_by_date = security_holdings.index_by(&:date)
        previous_holding = sorted.first

        sorted.first.date.upto(Date.current) do |date|
          holding = holdings_by_date[date]

          if holding
            filled_holdings << holding
            previous_holding = holding
          else
            # Carry the previous day's data forward, including cost_basis so
            # avg_cost/trend stay consistent across gap-filled days.
            filled_holdings << Holding.new(
              account: previous_holding.account,
              security: previous_holding.security,
              date: date,
              qty: previous_holding.qty,
              price: previous_holding.price,
              currency: previous_holding.currency,
              amount: previous_holding.amount,
              cost_basis: previous_holding.cost_basis
            )
          end
        end
      end

      filled_holdings
    end
  end
end
