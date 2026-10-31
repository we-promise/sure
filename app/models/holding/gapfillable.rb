module Holding::Gapfillable
  extend ActiveSupport::Concern

  class_methods do
    def gapfill(holdings)
      filled_holdings = []
      splits = splits_for(holdings)

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
            # Carry the previous day forward, through any split going ex today.
            #
            # A day with no price emits no holding, so a split on such a day
            # used to be filled over with the pre-split share count and
            # per-share cost -- and stayed that way for every day after it,
            # which for a security whose prices have stopped means forever.
            # A split moves no money: the count scales, the per-share price and
            # cost move by the inverse, and the position's value is unchanged.
            ratio = splits[[ security_id, date ]]
            previous_holding = carry_through_split(previous_holding, ratio) if ratio

            filled_holdings << Holding::HoldingData.new(
              account_id: previous_holding.account_id,
              security_id: previous_holding.security_id,
              date: date,
              qty: previous_holding.qty,
              price: previous_holding.price,
              currency: previous_holding.currency,
              amount: previous_holding.amount,
              cost_basis: previous_holding.cost_basis,
              cost_basis_unknown: previous_holding.cost_basis_unknown
            )
          end
        end
      end

      filled_holdings
    end

    private
      # The splits these holdings could be filled across, by security and
      # ex-date. One query for the whole set rather than one per filled day.
      def splits_for(holdings)
        return {} if holdings.empty?

        Security::Split
          .where(security_id: holdings.map(&:security_id).uniq, ex_date: holdings.min_by(&:date).date..Date.current)
          .to_h { |split| [ [ split.security_id, split.ex_date ], split.ratio ] }
      end

      # The same holding restated in post-split terms. `amount` is deliberately
      # recomputed from the scaled count and the inverse-scaled price rather
      # than carried, so the two cannot drift apart at the rounding the stored
      # scale imposes.
      def carry_through_split(holding, ratio)
        qty = Security::Split.scale(holding.qty, ratio)
        price = Security::Split.unscale(holding.price, ratio)

        Holding::HoldingData.new(
          account_id: holding.account_id,
          security_id: holding.security_id,
          date: holding.date,
          qty: qty,
          price: price,
          currency: holding.currency,
          amount: qty * price,
          cost_basis: holding.cost_basis && Security::Split.unscale(holding.cost_basis, ratio),
          cost_basis_unknown: holding.cost_basis_unknown
        )
      end
  end
end
