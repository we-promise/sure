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

    # Converts holdings into account currency per date.
    # Uses batched FX lookups (exact date, then nearest lookback) and omits any
    # foreign-currency holding that still has no rate — never falls back to 1:1.
    def holdings_value_by_date
      @holdings_value_by_date ||= begin
        holdings = account.holdings.to_a
        holdings.group_by(&:date).each_with_object(Hash.new(0)) do |(date, day_holdings), totals|
          foreign_currencies = day_holdings
            .map(&:currency)
            .uniq
            .reject { |currency| currency == account.currency }

          rates = ExchangeRate.rates_for(
            foreign_currencies,
            to: account.currency,
            date: date,
            fallback: nil
          )

          day_holdings.each do |holding|
            if holding.currency == account.currency
              totals[date] += holding.amount
              next
            end

            rate = rates[holding.currency]
            if rate.nil?
              Rails.logger.warn(
                "Balance::SyncCache omitting holding #{holding.id} " \
                "(#{holding.currency}→#{account.currency} on #{date}): no exchange rate"
              )
              next
            end

            totals[date] += holding.amount * rate
          end
        end
      end
    end

    def converted_entries
      @converted_entries ||= account.entries.excluding_split_parents.includes(:entryable).order(:date).to_a.map do |e|
        converted_entry = e.dup
        # dup does not copy the association cache, so the entryable would
        # be re-fetched on access. Copy it to keep the preload active.
        converted_entry.association(:entryable).target = e.entryable

        custom_rate = e.entryable.exchange_rate if e.entryable.respond_to?(:exchange_rate)

        # Use Money#exchange_to with custom rate if available, standard lookup otherwise
        converted_entry.amount = converted_entry.amount_money.exchange_to(
          account.currency,
          date: e.date,
          custom_rate: custom_rate
        ).amount

        converted_entry.currency = account.currency
        converted_entry
      end
    end
end
