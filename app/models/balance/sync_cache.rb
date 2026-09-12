class Balance::SyncCache
  def initialize(account)
    @account = account
    @unconvertible_entry_count = 0
    @unconvertible_holding_count = 0
  end

  # How many entries were left out of the balance calculation because no exchange rate was
  # available to convert them into the account's currency. Populated once `converted_entries`
  # has run; zero on a healthy sync.
  def unconvertible_entry_count
    entries_by_date
    @unconvertible_entry_count
  end

  # How many holdings were counted at a 1:1 rate for the same reason, overstating or
  # understating the holdings total by the FX gap. Populated once `holdings_value_by_date`
  # has run; zero on a healthy sync.
  def unconvertible_holding_count
    holdings_value_by_date
    @unconvertible_holding_count
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
        missing_rate_pairs = []
        rows = account.holdings.pluck(:id, :date, :amount, :currency)
        totals = rows.group_by { |(_id, date, _amount, _currency)| date }.each_with_object(Hash.new(0)) do |(date, day_rows), day_totals|
          day_rows = day_rows.reject { |(_id, _date, amount, _currency)| amount.zero? }

          foreign_currencies = day_rows
            .map { |(_id, _date, _amount, currency)| currency }
            .uniq
            .reject { |currency| currency == account.currency }

          # One batched lookup per date rather than a Money#exchange_to per holding,
          # which issues a rate query per row. rates_for already falls back to the
          # nearest recent rate, so weekend and holiday dates still convert.
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
              # Fall back to a 1:1 rate, which misstates the holding by the FX gap.
              # Excluding it instead would be worse here: `BaseCalculator#derive_cash_balance_on_date_from_total`
              # derives cash as `total_balance - holdings_value`, so a dropped holding reappears
              # as phantom cash. Report it rather than silently accepting the wrong number.
              day_totals[date] += amount
              @unconvertible_holding_count += 1
              missing_rate_pairs |= [ [ currency, account.currency ] ]
              next
            end

            day_totals[date] += amount * rate
          end
        end

        if @unconvertible_holding_count.positive?
          report_missing_rates(
            message: "Valued #{@unconvertible_holding_count} #{"holding".pluralize(@unconvertible_holding_count)} at a 1:1 rate: no exchange rate available",
            counts: { unconvertible_holding_count: @unconvertible_holding_count },
            missing_rate_pairs: missing_rate_pairs
          )
        end

        totals
      end
    end

    def converted_entries
      @converted_entries ||= begin
        missing_rate_pairs = []

        converted = account.entries.excluding_pending.excluding_split_parents.includes(:entryable).order(:date).to_a.filter_map do |e|
          custom_rate = e.entryable.exchange_rate if e.entryable.respond_to?(:exchange_rate)

          # Use Money#exchange_to with custom rate if available, standard lookup otherwise.
          # Mutate the entry in place rather than dup'ing — these instances are scoped to
          # this sync-cache only and never persisted, so avoiding the dup eliminates a
          # large amount of ActiveModel::Attribute allocations during sync.
          # to_a materializes independent instances; no AR identity map is active during sync,
          # so callers holding a reference to the same association will never see these mutations.
          begin
            new_amount = e.amount_money.exchange_to(
              account.currency,
              date: e.date,
              custom_rate: custom_rate
            ).amount
          rescue Money::ConversionError => error
            # Drop the entry instead of converting it at a made-up rate. A 1:1 fallback here
            # would silently misstate the balance by the size of the FX gap (see #1143), and
            # raising would abandon the whole account's balances over a single entry.
            @unconvertible_entry_count += 1
            missing_rate_pairs |= [ [ error.from_currency, error.to_currency ] ]
            next
          end

          e.amount = new_amount
          e.currency = account.currency
          e
        end

        if @unconvertible_entry_count.positive?
          report_missing_rates(
            message: "Excluded #{@unconvertible_entry_count} #{"entry".pluralize(@unconvertible_entry_count)} from balance calculation: no exchange rate available",
            counts: { unconvertible_entry_count: @unconvertible_entry_count },
            missing_rate_pairs: missing_rate_pairs
          )
        end

        converted
      end
    end

    def report_missing_rates(message:, counts:, missing_rate_pairs:)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        source: "Balance::SyncCache",
        message: message,
        account: account,
        family: account.family,
        provider_key: exchange_rate_provider_key,
        metadata: {
          account_currency: account.currency,
          missing_rate_pairs: missing_rate_pairs.map { |from, to| "#{from}->#{to}" }
        }.merge(counts)
      )
    end

    # Which FX backend was configured when the rate came up missing, so support can filter
    # these entries by provider. Read from the setting rather than `ExchangeRate.provider`,
    # which raises on an unrecognized configuration — diagnostics must never fail the sync.
    def exchange_rate_provider_key
      ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
    rescue StandardError
      nil
    end
end
