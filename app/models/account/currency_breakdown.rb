# Native (unconverted) balances per currency for accounts that hold more than
# one currency, e.g. a dual-currency credit card.
#
# Each currency line is the net of its own transactions using the account's
# sign convention. The account currency's line also includes the opening
# balance. Reconciliation valuations are not applied per currency.
module Account::CurrencyBreakdown
  extend ActiveSupport::Concern

  # True when the account currency plus its transaction currencies span more
  # than one currency, so a per-currency breakdown is meaningful.
  def multi_currency_breakdown?
    native_currency_balances.size > 1
  end

  # Returns Money balances, one per currency with the account currency first.
  # Empty when the account is not multi-currency.
  def native_currency_balances
    @native_currency_balances ||= begin
      sums = breakdown_transactions.group(:currency).sum(:amount)
      currencies = ([ currency ] + sums.keys).uniq

      if currencies.size > 1
        currencies.map do |code|
          flow = sums.fetch(code, 0)
          balance = asset? ? -flow : flow
          balance += opening_anchor_balance if code == currency
          Money.new(balance, code)
        end
      else
        []
      end
    end
  end

  private
    # Non-pending, non-split-parent transaction entries, the rows that count
    # toward each currency's native balance.
    def breakdown_transactions
      entries.excluding_pending.excluding_split_parents.where(entryable_type: "Transaction")
    end
end
