# Builders for the portfolio returns-engine test fixtures.
#
# `lay_balance` refuses to persist a day whose components do not add up to the
# closing figure the caller asked for. That strictness is the point: a test that
# quietly absorbed its own arithmetic error into `cash_adjustments` would still
# pass, and would be asserting the author's mistake rather than the rule.
module PortfolioReturnsTestHelper
  # The scale of every amount column on `balances` (db/schema.rb).
  BALANCE_SCALE = 4

  def create_portfolio_account(family:, currency: "USD", balance: 0, cash_balance: 0, name: nil)
    family.accounts.create!(
      name: name || "Brokerage #{SecureRandom.hex(3)}",
      balance: balance,
      cash_balance: cash_balance,
      currency: currency,
      accountable: Investment.new
    )
  end

  # One day of balance history, in the ACCOUNT's currency.
  #
  #   opening     the day's start_balance (== the previous day's close)
  #   closing     the day's end_balance
  #   cash_flow   signed cash movement (+ in, - out) -- deposits, withdrawals, income
  #   market_flow change in holdings value (net_market_flows)
  #   revaluation valuation/reconciliation movement (non_cash_adjustments)
  #
  # Every amount must be representable at the column's scale. `balances` stores
  # four decimal places, so a finer input is rounded on the way in, and
  # components that add up here can then miss the closing balance once stored:
  # 0.00005 + 0.00005 == 0.0001, but each persists as 0.0001 and the stored
  # end_balance becomes 0.0002 against a balance of 0.0001.
  def lay_balance(account:, date:, opening:, closing:, cash_flow: 0, market_flow: 0, revaluation: 0)
    amounts = { opening: opening, closing: closing, cash_flow: cash_flow, market_flow: market_flow, revaluation: revaluation }
      .transform_values { |value| BigDecimal(value.to_s) }

    amounts.each do |name, value|
      next if value.round(BALANCE_SCALE) == value

      raise ArgumentError,
            "#{name} #{value.to_s("F")} is finer than the #{BALANCE_SCALE} decimal places balances store, " \
            "so it would persist as #{value.round(BALANCE_SCALE).to_s("F")}"
    end

    opening, closing, cash_flow, market_flow, revaluation = amounts.values_at(:opening, :closing, :cash_flow, :market_flow, :revaluation)

    expected = opening + cash_flow + market_flow + revaluation
    unless expected == closing
      raise ArgumentError,
            "components do not reach the closing balance: #{opening} + #{cash_flow} + " \
            "#{market_flow} + #{revaluation} = #{expected}, asked for #{closing}"
    end

    account.balances.create!(
      date: date,
      currency: account.currency,
      balance: closing,
      cash_balance: opening + cash_flow,
      start_cash_balance: opening,
      start_non_cash_balance: 0,
      cash_inflows: cash_flow.positive? ? cash_flow : 0,
      cash_outflows: cash_flow.negative? ? -cash_flow : 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: market_flow,
      cash_adjustments: 0,
      non_cash_adjustments: revaluation,
      flows_factor: 1
    )
  end

  # An external contribution (positive `amount`) or withdrawal (negative), in
  # the natural reading. Stored with the codebase's sign convention, where
  # entries.amount is negative for money arriving.
  def deposit(account:, date:, amount:, currency: nil)
    account.entries.create!(
      name: amount.positive? ? "Deposit" : "Withdrawal",
      date: date,
      amount: -BigDecimal(amount.to_s),
      currency: currency || account.currency,
      entryable: Transaction.new(kind: "standard")
    )
  end

  # A dividend or interest payment, in the Trade shape #1311 introduced
  # (qty: 0, price: 0, value in the entry amount).
  def income_trade(account:, date:, amount:, label: "Dividend", currency: nil, security: nil)
    account.entries.create!(
      name: label,
      date: date,
      amount: -BigDecimal(amount.to_s),
      currency: currency || account.currency,
      entryable: Trade.new(
        security: security || security_under_test,
        qty: 0,
        price: 0,
        currency: currency || account.currency,
        investment_activity_label: label
      )
    )
  end

  # The other storage shape: a Transaction carrying the label, which is what
  # Trading212 and SimpleFIN write.
  #
  # `extra` is the provider payload, where a security is recorded when the
  # provider knew one: `{ "security_id" => id }` (flat) or
  # `{ "security" => { "id" => id } }` (nested). Left out, it is the common case
  # this shape exists to cover -- a dividend with no security attached.
  def income_transaction(account:, date:, amount:, label: "Dividend", currency: nil, extra: nil)
    account.entries.create!(
      name: label,
      date: date,
      amount: -BigDecimal(amount.to_s),
      currency: currency || account.currency,
      entryable: Transaction.new(kind: "standard", investment_activity_label: label, extra: extra || {})
    )
  end

  def fee_entry(account:, date:, amount:, currency: nil)
    account.entries.create!(
      name: "Fee",
      date: date,
      amount: BigDecimal(amount.to_s),
      currency: currency || account.currency,
      entryable: Transaction.new(kind: "standard", investment_activity_label: "Fee")
    )
  end

  def buy_trade(account:, date:, qty:, price:, currency: nil)
    account.entries.create!(
      name: "Buy",
      date: date,
      amount: BigDecimal((qty * price).to_s),
      currency: currency || account.currency,
      entryable: Trade.new(
        security: security_under_test,
        qty: qty,
        price: price,
        currency: currency || account.currency,
        investment_activity_label: "Buy"
      )
    )
  end

  # A disposal. Mirrors buy_trade with a negative qty, which is the whole
  # difficulty this shape creates: a security journal (below) is written the
  # same way and only the label tells them apart.
  def sell_trade(account:, date:, qty:, price:, currency: nil, label: "Sell", security: nil)
    account.entries.create!(
      name: "Sell",
      date: date,
      amount: BigDecimal((-qty.abs * price).to_s),
      currency: currency || account.currency,
      entryable: Trade.new(
        security: security || security_under_test,
        qty: -qty.abs,
        price: price,
        currency: currency || account.currency,
        investment_activity_label: label
      )
    )
  end

  # A holdings snapshot carrying an explicit cost basis, so a test's expected
  # gain is hand-computable: Holding#avg_cost returns the stored cost_basis as
  # the per-share average whenever it is positive or locked, without falling
  # back to deriving one from trades.
  #
  # `cost_basis: nil` is the "cannot be determined" case -- with no buy trades
  # behind it, calculate_avg_cost has nothing to average and returns nil.
  def holding_snapshot(account:, date:, qty:, price:, cost_basis:, security: nil)
    account.holdings.create!(
      security: security || security_under_test,
      date: date,
      qty: qty,
      price: price,
      amount: BigDecimal((qty * price).to_s),
      currency: account.currency,
      cost_basis: cost_basis
    )
  end

  # A security journal: a position moved in or out of the account, written as a
  # Transfer-labelled trade with no cash value. Questrade writes exactly this
  # shape (QuestradeAccount::ActivitiesProcessor -- price: 0, amount: 0), and
  # the zero amount is the point: the position moves, no money does.
  #
  # Written as a Transfer-labelled trade with
  # `price: 0, amount: 0`, which is what Questrade's processor produces.
  #
  # `price:` writes the holdings row the position is valued from on that date --
  # the row Balance::BaseCalculator reads, and the one a journal's flow is valued from.
  # Omit it to model a journal date with no price: a weekend, a holiday, or an
  # instance with no feed. `holding_qty:` defaults to the journalled quantity
  # and is passed explicitly when the account already held some of the security,
  # so the holding row carries the whole position while the journal moved only
  # part of it.
  def security_journal(account:, date:, qty:, currency: nil, price: nil, holding_qty: nil)
    entry = account.entries.create!(
      name: "Journal",
      date: date,
      amount: 0,
      currency: currency || account.currency,
      entryable: Trade.new(
        security: security_under_test,
        qty: qty,
        price: 0,
        currency: currency || account.currency,
        investment_activity_label: "Transfer"
      )
    )

    if price
      # After the journal: the arriving quantity for a journal in, and whatever
      # is left for a journal out -- zero when the whole position went. The row
      # still carries the security's price, which is what the flow is valued
      # from, and `holdings` refuses a negative quantity.
      held = holding_qty || [ qty, 0 ].max
      account.holdings.create!(
        security: security_under_test, date: date, qty: held, price: price,
        amount: BigDecimal(held.to_s) * BigDecimal(price.to_s),
        currency: currency || account.currency
      )
    end

    entry
  end

  def set_rate(from:, to:, date:, rate:)
    ExchangeRate.find_or_create_by!(from_currency: from, to_currency: to, date: date) do |record|
      record.rate = rate
    end.tap { |record| record.update!(rate: rate) }
  end

  def security_under_test
    @security_under_test ||= Security.create!(ticker: "TST#{SecureRandom.hex(4)}", name: "Test Security")
  end
end
