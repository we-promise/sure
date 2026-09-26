# Builders for the entry shapes providers actually write into investment
# accounts, so classifier and totals tests exercise real storage shapes
# rather than one idealised trade. The provider each shape comes from is
# recorded in docs/portfolio/methodology.md (provider audit).
module PortfolioFlowTestHelper
  def create_portfolio_account(family, name: "Investment #{SecureRandom.hex(3)}", balance: 1000, cash_balance: 0, currency: "USD", accountable: Investment.new)
    family.accounts.create!(
      name: name,
      balance: balance,
      cash_balance: cash_balance,
      currency: currency,
      accountable: accountable
    )
  end

  def create_portfolio_security(ticker: "T#{SecureRandom.hex(6)}")
    Security.create!(ticker: ticker, name: "Test #{ticker}")
  end

  # Manual buy/sell (Trade::CreateForm) and provider trades. The manual form
  # folds the fee into the entry amount; pass `fee_in_amount: false` for the
  # Kraken / Binance-spot shape whose amount excludes it.
  def create_portfolio_trade(account:, security: create_portfolio_security, qty:, price:, fee: 0, label: nil, date: Date.current, fee_in_amount: true, excluded: false)
    label ||= qty.negative? ? "Sell" : "Buy"
    amount = qty.to_d * price.to_d
    amount += fee.to_d if fee_in_amount

    account.entries.create!(
      name: "#{label} #{security.ticker}",
      date: date,
      amount: amount,
      currency: account.currency,
      excluded: excluded,
      entryable: Trade.new(
        qty: qty,
        price: price,
        fee: fee,
        currency: account.currency,
        security: security,
        investment_activity_label: label
      )
    )
  end

  # Trade::CreateForm#create_income_trade: qty 0, price 0, negative amount.
  def create_income_trade(account:, label:, amount:, security: create_portfolio_security, date: Date.current)
    account.entries.create!(
      name: "#{label}: #{security.ticker}",
      date: date,
      amount: -amount.to_d.abs,
      currency: account.currency,
      entryable: Trade.new(qty: 0, price: 0, fee: 0, currency: account.currency, security: security, investment_activity_label: label)
    )
  end

  # Trading212 / IBKR / Questrade: a Transaction with the label and the
  # security id in extra. Negative amount = cash in.
  def create_income_transaction(account:, label:, amount:, security: create_portfolio_security, date: Date.current, extra_shape: :flat)
    extra = case extra_shape
    when :flat then { "security_id" => security.id }
    when :nested then { "security" => { "id" => security.id } }
    else {}
    end

    account.entries.create!(
      name: "#{label} from #{security.ticker}",
      date: date,
      amount: -amount.to_d.abs,
      currency: account.currency,
      entryable: Transaction.new(investment_activity_label: label, extra: extra)
    )
  end

  # PlaidAccount::Investments::TransactionsProcessor routes a cash dividend
  # through the trade path with quantity 0, so the amount is 0 * price = 0.
  def create_plaid_dividend_trade(account:, security: create_portfolio_security, price: 100, date: Date.current)
    account.entries.create!(
      name: "Dividend #{security.ticker}",
      date: date,
      amount: 0,
      currency: account.currency,
      entryable: Trade.new(qty: 0, price: price, fee: 0, currency: account.currency, security: security, investment_activity_label: "Dividend")
    )
  end

  def create_labelled_transaction(account:, label:, amount:, kind: "standard", date: Date.current, extra: {}, excluded: false)
    account.entries.create!(
      name: "#{label || 'Transaction'} #{SecureRandom.hex(2)}",
      date: date,
      amount: amount,
      currency: account.currency,
      excluded: excluded,
      entryable: Transaction.new(investment_activity_label: label, kind: kind, extra: extra)
    )
  end

  # A linked Transfer exactly as Transfer::Creator writes it: the outflow leg
  # is investment_contribution when the destination is an investment account,
  # the inflow leg is funds_movement, and optional fee legs point back at the
  # transfer through transfer_id.
  def create_linked_transfer(family:, from:, to:, amount:, date: Date.current, source_fee_amount: nil)
    Transfer::Creator.new(
      family: family,
      source_account_id: from.id,
      destination_account_id: to.id,
      date: date,
      amount: amount,
      source_fee_amount: source_fee_amount
    ).create
  end

  # A position moved between two accounts: no Transfer row, two Transfer
  # trades with opposite quantities on the same security and date.
  def create_security_transfer(security:, from:, to:, qty:, price:, date: Date.current)
    [
      create_portfolio_trade(account: from, security: security, qty: -qty, price: price, label: "Transfer", date: date),
      create_portfolio_trade(account: to, security: security, qty: qty, price: price, label: "Transfer", date: date)
    ]
  end
end
