class Balance::SyncCache
  def initialize(account)
    @account = account
  end

  def get_valuation(date)
    entries_by_date[date]&.find { |e| e.valuation? }
  end

  def get_holdings_value(date)
    return nil if unknown_holdings_value_dates.key?(date)

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
    # Uses batched FX lookups (exact date, then nearest lookback). A date with
    # any unconvertible foreign holding is unknown, rather than silently treating
    # that holding as 1:1 or zero. Callers use nil to preserve existing balance
    # components and avoid reclassifying unknown investments as cash.
    #
    # Zero-amount rows (sold-out positions, neutralized manual rows) are skipped:
    # they contribute nothing to the total and must not demand FX or mark the
    # whole date unknown when rates are missing.
    def holdings_value_by_date
      @holdings_value_by_date ||= begin
        @unknown_holdings_value_dates = {}
        unknown_fx = Hash.new { |pairs, key| pairs[key] = { count: 0, first_date: nil, last_date: nil } }
        rows = account.holdings.pluck(:id, :date, :amount, :currency)
        totals = rows.group_by { |(_id, date, _amount, _currency)| date }.each_with_object(Hash.new(0)) do |(date, day_rows), day_totals|
          day_rows = day_rows.reject { |(_id, _date, amount, _currency)| amount.zero? }

          foreign_currencies = day_rows
            .map { |(_id, _date, _amount, currency)| currency }
            .uniq
            .reject { |currency| currency == account.currency }

          rates = ExchangeRate.rates_for(
            foreign_currencies,
            to: account.currency,
            date: date,
            fallback: nil
          )

          day_rows.each do |_id, _date, amount, currency|
            if currency == account.currency
              day_totals[date] += amount
              next
            end

            rate = rates[currency]
            if rate.nil?
              @unknown_holdings_value_dates[date] = true
              record_unknown_fx_conversion(unknown_fx, from: currency, to: account.currency, date: date)
              next
            end

            day_totals[date] += amount * rate
          end
        end

        log_unknown_fx_conversions(unknown_fx)
        totals
      end
    end

    def record_unknown_fx_conversion(unknown_fx, from:, to:, date:)
      stats = unknown_fx[[ from, to ]]
      stats[:count] += 1
      stats[:first_date] = stats[:first_date] ? [ stats[:first_date], date ].min : date
      stats[:last_date] = stats[:last_date] ? [ stats[:last_date], date ].max : date
    end

    def log_unknown_fx_conversions(unknown_fx)
      unknown_fx.each do |(from_currency, to_currency), stats|
        DebugLogEntry.capture(
          category: "exchange_rate_conversion",
          level: "warn",
          message: "Cannot convert holding into account currency",
          source: self.class.name,
          family: account.family,
          account: account,
          account_provider: account_provider,
          metadata: {
            from_currency: from_currency,
            to_currency: to_currency,
            holdings_affected: stats[:count],
            first_date: stats[:first_date],
            last_date: stats[:last_date]
          }
        )
      end
    end

    def unknown_holdings_value_dates
      holdings_value_by_date
      @unknown_holdings_value_dates
    end

    def account_provider
      @account_provider ||= account.account_providers.first
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
