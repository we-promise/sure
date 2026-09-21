# Native (unconverted) balances per currency for accounts whose transactions
# are recorded in more than one currency, e.g. a dual-currency credit card.
#
# Each currency line is the net of its own transactions using the account's
# sign convention. The account currency's line also includes the opening
# balance. Reconciliation valuations are not applied per currency.
module Account::CurrencyBreakdown
  extend ActiveSupport::Concern

  def multi_currency_breakdown?
    transaction_currencies.size > 1
  end

  # Returns Money values keyed by currency, account currency first.
  def native_currency_balances
    return [] unless multi_currency_breakdown?

    sums = entries.excluding_pending.excluding_split_parents
                  .where(entryable_type: "Transaction")
                  .group(:currency).sum(:amount)

    currencies = ([ currency ] + transaction_currencies).uniq
    currencies.map do |code|
      flow = sums.fetch(code, 0)
      balance = asset? ? -flow : flow
      balance += opening_anchor_balance if code == currency
      Money.new(balance, code)
    end
  end

  private
    def transaction_currencies
      entries.excluding_pending.excluding_split_parents
             .where(entryable_type: "Transaction").distinct.pluck(:currency)
    end
end
