class Balance::SyncCache
  def initialize(account)
    @account = account
  end

  def get_valuation(date)
    entries_by_date[date]&.find { |e| e.valuation? }
  end

  def get_holdings_value(date)
    holdings_value_by_date[date] || 0
  end

  def get_entries(date)
    entries_by_date[date]&.select { |e| e.transaction? || e.trade? } || []
  end

  private
    attr_reader :account

    def entries_by_date
      @entries_by_date ||= converted_entries.group_by(&:date)
    end

    def holdings_value_by_date
      @holdings_value_by_date ||= account.holdings.each_with_object(Hash.new(0)) do |h, totals|
        begin
          converted = Money.new(h.amount, h.currency).exchange_to(account.currency, date: h.date).amount
        rescue Money::ConversionError
          converted = h.amount # fallback to 1:1 conversion rate if exchange rate unavailable
        end
        totals[h.date] += converted
      end
    end

    def converted_entries
      @converted_entries ||= account.entries.excluding_split_parents.includes(:entryable).order(:date).to_a.map do |e|
        custom_rate = e.entryable.exchange_rate if e.entryable.respond_to?(:exchange_rate)

        # Use Money#exchange_to with custom rate if available, standard lookup otherwise.
        # Mutate the entry in place rather than dup'ing — these instances are scoped to
        # this sync-cache only and never persisted, so avoiding the dup eliminates a
        # large amount of ActiveModel::Attribute allocations during sync.
        # to_a materializes independent instances; no AR identity map is active during sync,
        # so callers holding a reference to the same association will never see these mutations.
        new_amount = e.amount_money.exchange_to(
          account.currency,
          date: e.date,
          custom_rate: custom_rate
        ).amount

        e.amount = new_amount
        e.currency = account.currency
        e
      end
    end
end
