class Balance::SyncCache
  def initialize(account)
    @account = account
    @unconvertible_entry_count = 0
    @missing_rate_pairs = []
  end

  # How many entries were left out of the balance calculation because no exchange rate was
  # available to convert them into the account's currency. Populated once `converted_entries`
  # has run; zero on a healthy sync.
  def unconvertible_entry_count
    entries_by_date
    @unconvertible_entry_count
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
      @converted_entries ||= begin
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
            @missing_rate_pairs |= [ [ error.from_currency, error.to_currency ] ]
            next
          end

          e.amount = new_amount
          e.currency = account.currency
          e
        end

        report_unconvertible_entries if @unconvertible_entry_count.positive?

        converted
      end
    end

    def report_unconvertible_entries
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        source: "Balance::SyncCache",
        message: "Excluded #{@unconvertible_entry_count} #{"entry".pluralize(@unconvertible_entry_count)} from balance calculation: no exchange rate available",
        account: account,
        family: account.family,
        provider_key: exchange_rate_provider_key,
        metadata: {
          account_currency: account.currency,
          unconvertible_entry_count: @unconvertible_entry_count,
          missing_rate_pairs: @missing_rate_pairs.map { |from, to| "#{from}->#{to}" }
        }
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
