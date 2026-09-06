class Loan
  # Resolves linked asset balances into the change-point shape consumed by the
  # daily simulator. Historical ranges use each account's end-of-day balance;
  # ranges at and after today use the accounts' current totals held flat.
  class OffsetResolver
    def initialize(loan)
      @loan = loan
    end

    def change_points(from_date, to_date)
      return [] unless @loan.offset_accounts.exists?
      return [] if from_date >= to_date

      today = Date.current
      return [ { date: from_date, amount: current_total } ] if from_date >= today

      historical_end = [ to_date - 1, today ].min
      points = historical_points(from_date, historical_end)
      if to_date > today
        points << { date: today, amount: current_total }
      end
      points.uniq { |point| point[:date] }
    end

    private

      def offset_accounts
        @offset_accounts ||= @loan.offset_accounts.to_a
      end

      def current_total
        Account.where(id: offset_accounts.map(&:id)).sum(:balance).to_d
      end

      def historical_points(from_date, to_date)
        balances = offset_accounts.index_with do |account|
          account.balances.where("date < ?", from_date).order(date: :desc).first
        end
        points = [ { date: from_date, amount: balances.values.sum(BigDecimal("0")) { |balance| balance_value(balance) } } ]

        Balance.where(account_id: offset_accounts.map(&:id), date: (from_date..to_date))
          .order(:date, :account_id)
          .find_each do |balance|
            balances[balance.account_id] = balance
            points << { date: balance.date, amount: balances.values.sum(BigDecimal("0")) { |row| balance_value(row) } }
          end

        points.group_by { |point| point[:date] }.values.map(&:last)
      end

      def balance_value(balance)
        BigDecimal((balance&.end_balance || 0).to_s)
      end
  end
end
