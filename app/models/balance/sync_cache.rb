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
        converted_entry = e.dup
        # dup does not copy the association cache, so the entryable would
        # be re-fetched on access. Copy it to keep the preload active.
        converted_entry.association(:entryable).target = e.entryable

        custom_rate = e.entryable.exchange_rate if e.entryable.respond_to?(:exchange_rate)

        # Use Money#exchange_to with custom rate if available, standard lookup
        # otherwise. On a missing historical rate, DROP the entry from the
        # cache (not retain+relabel). The downstream flow/derivation in
        # Balance::BaseCalculator sums entry.amount across the day with no
        # currency awareness (see #flows_for_date's `sum(&:amount)`), so:
        #   - keeping the source-currency nominal and relabeling it to
        #     account.currency would silently treat a 100 EUR entry as
        #     100 #{account.currency} in the balance series (currency laundering),
        #   - keeping the entry in its source currency would mix currencies
        #     in the naive sum.
        # Dropping is the honest failure mode: that day's balance omits the
        # unconvertible foreign entry rather than booking a fabricated value,
        # and the logged warn surfaces it for support — while preserving the
        # resilience policy (a single bad entry can't crash the whole sync),
        # mirroring holdings_value_by_date's non-crashing rescue.
        converted_entry.amount =
          begin
            converted_entry.amount_money.exchange_to(
              account.currency,
              date: e.date,
              custom_rate: custom_rate
            ).amount
          rescue Money::ConversionError
            Rails.logger.warn(
              "Balance::SyncCache - dropped entry #{e.id} on account #{account.id}: " \
              "no FX rate to convert to #{account.currency} on #{e.date}"
            )
            next nil
          end

        converted_entry.currency = account.currency
        converted_entry
      end.compact
    end
end
