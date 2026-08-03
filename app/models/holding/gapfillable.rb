module Holding::Gapfillable
  extend ActiveSupport::Concern

  class_methods do
    def gapfill(holdings)
      filled_holdings = []
      provider_cash_equivalent_snapshots = provider_cash_equivalent_snapshots_for(holdings)

      holdings.group_by { |h| h.security_id }.each do |security_id, security_holdings|
        next if security_holdings.empty?

        sorted = security_holdings.sort_by(&:date)
        holdings_by_date = security_holdings.index_by(&:date)
        previous_holding = sorted.first

        sorted.first.date.upto(Date.current) do |date|
          holding = holdings_by_date[date]
          provider_cash_equivalent = provider_cash_equivalent_for(
            provider_cash_equivalent_snapshots,
            account_id: previous_holding.account_id,
            security_id: security_id,
            date: date
          )

          if holding
            holding.cash_equivalent = provider_cash_equivalent unless provider_cash_equivalent.nil?
            filled_holdings << holding
            previous_holding = holding
          else
            # Create a new holding based on the previous day's data
            filled_holdings << Holding.new(
              account: previous_holding.account,
              security: previous_holding.security,
              date: date,
              qty: previous_holding.qty,
              price: previous_holding.price,
              currency: previous_holding.currency,
              amount: previous_holding.amount,
              cash_equivalent: provider_cash_equivalent.nil? ? previous_holding.cash_equivalent? : provider_cash_equivalent
            )
          end
        end
      end

      filled_holdings
    end

    private
      def provider_cash_equivalent_snapshots_for(holdings)
        account_ids = holdings.map(&:account_id).compact.uniq
        security_ids = holdings.map(&:security_id).compact.uniq
        return {} if account_ids.empty? || security_ids.empty?

        Holding
          .where(account_id: account_ids, security_id: security_ids)
          .where.not(account_provider_id: nil)
          .order(:date)
          .pluck(:account_id, :security_id, :date, :cash_equivalent)
          .group_by { |account_id, security_id, _date, _cash_equivalent| [ account_id, security_id ] }
          .transform_values { |snapshots| snapshots.map { |_, _, date, cash_equivalent| [ date, cash_equivalent ] } }
      end

      def provider_cash_equivalent_for(snapshots, account_id:, security_id:, date:)
        security_snapshots = snapshots[[ account_id, security_id ]]
        return nil if security_snapshots.blank?

        snapshot = security_snapshots.reverse.find { |snapshot_date, _| snapshot_date <= date } || security_snapshots.first
        snapshot.last
      end
  end
end
