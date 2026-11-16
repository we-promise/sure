module EntriesTestHelper
  def create_transaction(attributes = {})
    entry_attributes = attributes.except(:category, :tags, :merchant, :kind)
    transaction_attributes = attributes.slice(:category, :tags, :merchant, :kind)

    entry_defaults = {
      account: accounts(:depository),
      name: "Transaction",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new(transaction_attributes)
    }

    Entry.create! entry_defaults.merge(entry_attributes)
  end

  def create_valuation(attributes = {})
    entry_attributes = attributes.except(:kind)
    valuation_attributes = attributes.slice(:kind)

    account = attributes[:account] || accounts(:depository)
    amount = attributes[:amount] || 5000

    entry_defaults = {
      account: account,
      name: "Valuation",
      date: 1.day.ago.to_date,
      currency: "USD",
      amount: amount,
      entryable: Valuation.new({ kind: "reconciliation" }.merge(valuation_attributes))
    }

    Entry.create! entry_defaults.merge(entry_attributes)
  end

  def create_trade(security, account:, qty:, date:, price: nil, currency: "USD", fee: 0)
    trade_price = price || Security::Price.find_by!(security: security, date: date).price

    trade = Trade.new \
      qty: qty,
      security: security,
      price: trade_price,
      currency: currency,
      fee: fee,
      investment_activity_label: qty > 0 ? "Buy" : "Sell"

    account.entries.create! \
      name: "Trade",
      date: date,
      amount: qty * trade_price,
      currency: currency,
      entryable: trade
  end

  def create_transfer(from_account:, to_account:, amount:, date: Date.current, currency: "USD", source_fee_amount: 0, destination_fee_amount: 0)
    outflow_transaction = Transaction.create!(kind: "funds_movement")
    inflow_transaction = Transaction.create!(kind: "funds_movement")

    transfer = Transfer.create!(
      outflow_transaction: outflow_transaction,
      inflow_transaction: inflow_transaction,
      amount: amount.abs,
      status: "confirmed" # like Transfer::Creator; only a confirmed transfer carries transfer kinds
    )

    from_account.entries.create!(
      name: "Transfer to #{to_account.name}",
      date: date,
      amount: amount.abs,
      currency: currency,
      entryable: outflow_transaction
    )

    to_account.entries.create!(
      name: "Transfer from #{from_account.name}",
      date: date,
      amount: -(amount.abs),
      currency: currency,
      entryable: inflow_transaction
    )

    if source_fee_amount > 0
      fee_tx = Transaction.create!(
        kind: "standard",
        entry: from_account.entries.create!(
          name: "Transfer fee to #{to_account.name}",
          date: date,
          amount: source_fee_amount,
          currency: currency,
        )
      )
      transfer.fee_transactions << fee_tx
    end

    if destination_fee_amount > 0
      fee_tx = Transaction.create!(
        kind: "standard",
        entry: to_account.entries.create!(
          name: "Transfer fee from #{from_account.name}",
          date: date,
          amount: destination_fee_amount,
          currency: currency,
        )
      )
      transfer.fee_transactions << fee_tx
    end

    transfer
  end

  # A manual bill in `category` with no occurrences: creating a series
  # generates its own, which tests clear so they assert against exactly the
  # ones they add with pay_bill and expect_bill.
  def create_bill(category:, amount:, name: "Bill", day: 1, account: accounts(:depository))
    bill = category.family.recurring_transactions.create!(
      name: name, account: account, amount: amount, currency: "USD", bill_type: "bill",
      category_id: category.id, expected_day_of_month: day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    bill.recurring_occurrences.destroy_all
    bill
  end

  # The entry that pays `bill` on `date`, and the paid occurrence it settles.
  # The entry takes the bill's category unless `category:` says otherwise.
  def pay_bill(bill, date:, amount: bill.amount, category: bill.category)
    entry = create_transaction(category: category, account: bill.account, amount: amount, date: date, name: "#{bill.name} #{date}")
    occurrence = bill.recurring_occurrences.create!(
      family: bill.family, original_due_on: date, due_on: date, currency: bill.currency,
      expected_amount: amount, status: "paid", closed_at: Time.current, closed_source: "auto"
    )
    occurrence.allocations.create!(entry: entry, allocated_amount: amount, currency: bill.currency, source: "auto_matched")
    entry
  end

  # An occurrence of `bill` still waiting to be paid.
  def expect_bill(bill, due_on:, amount: bill.amount)
    bill.recurring_occurrences.create!(
      family: bill.family, original_due_on: due_on, due_on: due_on, currency: bill.currency, expected_amount: amount
    )
  end
end
