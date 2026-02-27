class Balance::SyncCache
  def initialize(account)
    @account = account
  end

  def get_valuation(date)
    entries_by_date[date]&.find { |e| e.valuation? }
  end

  def get_holdings(date)
    holdings_by_date[date] || []
  end

  def get_entries(date)
    entries_by_date[date]&.select { |e| e.transaction? || e.trade? } || []
  end

  private
    attr_reader :account

    def entries_by_date
      @entries_by_date ||= converted_entries.group_by(&:date)
    end

    def holdings_by_date
      @holdings_by_date ||= converted_holdings.group_by(&:date)
    end

    def converted_entries
      @converted_entries ||= account.entries.order(:date).to_a.map do |e|
        converted_entry = e.dup
        converted_entry.amount = converted_entry.amount_money.exchange_to(
          account.currency,
          date: e.date,
          fallback_rate: 1
        ).amount
        converted_entry.currency = account.currency
        converted_entry
      end
    end

    def converted_holdings
      @converted_holdings ||= account.holdings.map do |h|
        converted_holding = h.dup
        converted_holding.amount = converted_holding.amount_money.exchange_to(
          account.currency,
          date: h.date,
          fallback_rate: 1
        ).amount
        converted_holding.currency = account.currency
        converted_holding
      end
    end
end
