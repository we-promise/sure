require "test_helper"

class CreditCardTest < ActiveSupport::TestCase
  test "debt from available credit is the limit minus the reported amount" do
    assert_equal BigDecimal("16.17"),
      CreditCard.debt_from_available_credit(credit_limit: BigDecimal("5000"), available_credit: BigDecimal("4983.83"), clamp_overpayment: false)
  end

  test "an overpayment stays a credit balance unless clamped" do
    assert_equal BigDecimal("-20"),
      CreditCard.debt_from_available_credit(credit_limit: BigDecimal("5000"), available_credit: BigDecimal("5020"), clamp_overpayment: false)
    assert_equal 0,
      CreditCard.debt_from_available_credit(credit_limit: BigDecimal("5000"), available_credit: BigDecimal("5020"), clamp_overpayment: true)
  end

  test "the debt is unknown without a positive limit" do
    assert_nil CreditCard.debt_from_available_credit(credit_limit: nil, available_credit: BigDecimal("10"), clamp_overpayment: true)
    assert_nil CreditCard.debt_from_available_credit(credit_limit: BigDecimal("0"), available_credit: BigDecimal("10"), clamp_overpayment: true)
  end

  test "statement cycle days are bounded to a real day of the month" do
    card = CreditCard.new

    card.statement_close_day = 0
    assert_not card.valid?
    assert card.errors[:statement_close_day].present?

    card.statement_close_day = 32
    assert_not card.valid?
    assert card.errors[:statement_close_day].present?

    card.statement_close_day = 31
    card.due_day = 31
    assert card.valid?
  end

  test "a card with no account has no statement cycle" do
    assert_not CreditCard.new(statement_close_day: 25, due_day: 5).statement_cycle_configured?
  end

  test "a close day alone is not a cycle without an account" do
    card = CreditCard.new(statement_close_day: 25)
    card.account = accounts(:credit_card)

    assert card.statement_cycle_configured?
  end

  test "a card with no close day has no cycle dates" do
    card = CreditCard.new(due_day: 5)
    card.account = accounts(:credit_card)

    assert_not card.statement_cycle_configured?
    assert_nil card.last_statement_close_date
    assert_nil card.previous_statement_close_date
    assert_nil card.next_statement_close_date
    assert_nil card.next_payment_due_date
    assert_nil card.days_until_due
    assert_nil card.last_statement_balance_money
    assert_nil card.accrued_since_last_close_money
  end

  test "a close day without a due day still closes but never falls due" do
    card = CreditCard.new(statement_close_day: 25)
    card.account = accounts(:credit_card)

    assert_equal Date.new(2026, 10, 25), card.next_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_nil card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
    assert_nil card.days_until_due(as_of: Date.new(2026, 10, 16))
  end

  test "the last close is the close already past, and today counts as closed" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal Date.new(2026, 9, 25), card.last_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 10, 25), card.last_statement_close_date(as_of: Date.new(2026, 10, 25))
    assert_equal Date.new(2026, 9, 25), card.last_statement_close_date(as_of: Date.new(2026, 10, 24))
  end

  test "the previous close is one cycle back and the next one is one cycle on" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal Date.new(2026, 8, 25), card.previous_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 10, 25), card.next_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 11, 25), card.next_statement_close_date(as_of: Date.new(2026, 10, 25))
  end

  test "a close day past the month end clamps to the last day of that month" do
    card = statement_card(close_day: 31, due_day: 20)

    assert_equal Date.new(2026, 10, 31), card.last_statement_close_date(as_of: Date.new(2026, 11, 3))
    assert_equal Date.new(2026, 11, 30), card.next_statement_close_date(as_of: Date.new(2026, 11, 3))
    assert_equal Date.new(2028, 2, 29), card.last_statement_close_date(as_of: Date.new(2028, 3, 1))
    assert_equal Date.new(2027, 2, 28), card.last_statement_close_date(as_of: Date.new(2027, 3, 1))
  end

  test "a due day after the close day falls in the following month" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal Date.new(2026, 11, 5), card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
    assert_equal 20, card.days_until_due(as_of: Date.new(2026, 10, 16))
  end

  # The close and the due day both landing in the same calendar month is the
  # case a "next close" anchor gets wrong: the statement that closed on the
  # 16th of this month is due on the 26th of this month.
  test "a card closing early in the month is due later in the same month" do
    card = statement_card(close_day: 10, due_day: 26)

    assert_equal Date.new(2026, 10, 10), card.last_statement_close_date(as_of: Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 10, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
    assert_equal 10, card.days_until_due(as_of: Date.new(2026, 10, 16))
  end

  test "a card is still due today on the due date itself" do
    card = statement_card(close_day: 10, due_day: 26)

    assert_equal Date.new(2026, 10, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 26))
    assert_equal 0, card.days_until_due(as_of: Date.new(2026, 10, 26))
  end

  test "a passed due date gives way to the following statement" do
    card = statement_card(close_day: 10, due_day: 26)

    assert_equal Date.new(2026, 11, 26), card.next_payment_due_date(as_of: Date.new(2026, 10, 27))
    assert_equal 30, card.days_until_due(as_of: Date.new(2026, 10, 27))
  end

  test "the amount the next payment is made on is the statement already closed" do
    card = statement_card(close_day: 10, due_day: 26)
    account = card.account
    as_of = Date.new(2026, 10, 16)

    charge(account, Date.new(2026, 9, 20), 300)
    charge(account, Date.new(2026, 10, 12), 40)
    charge(account, Date.new(2026, 10, 14), 60)

    # The 300 statement is due on the 26th of this month, which is the payment
    # the cardholder is being asked about. The 40 and 60 land on the statement
    # that closes on the 10th of November and are still building.
    assert_equal 300, card.last_statement_balance_money(as_of: as_of).amount
    assert_equal 100, card.accrued_since_last_close_money(as_of: as_of).amount
  end

  test "a due day later in the same month is due this month" do
    card = statement_card(close_day: 5, due_day: 25)

    assert_equal Date.new(2026, 10, 25), card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
    assert_equal 9, card.days_until_due(as_of: Date.new(2026, 10, 16))
  end

  test "a due day landing on the close day is left alone" do
    card = statement_card(close_day: 15, due_day: 15)

    # Same day is a real arrangement, so the payment is not pushed a month out
    # for being equal to the close; it simply falls due the day it closes.
    assert_equal Date.new(2026, 10, 15), card.payment_due_date_for(Date.new(2026, 10, 15))
    # Read the day after, that one has passed and the next statement is due.
    assert_equal Date.new(2026, 11, 15), card.next_payment_due_date(as_of: Date.new(2026, 10, 16))
  end

  test "a due day earlier than the close day wraps even when clamping collapses both onto one day" do
    card = statement_card(close_day: 31, due_day: 28)

    # February collapses the 31st and the 28th onto the same day. The cardholder
    # configured the due day BEFORE the close day, so the statement that closed
    # on 28 February is due on 28 March -- not due the day it closes, and not
    # skipped over for 28 April once March arrives.
    travel_to Date.new(2026, 3, 1) do
      assert_equal Date.new(2026, 2, 28), card.last_statement_close_date
      assert_equal Date.new(2026, 3, 28), card.payment_due_date_for(Date.new(2026, 2, 28))
      assert_equal Date.new(2026, 3, 28), card.next_payment_due_date
    end
  end

  test "an unpaid passed due date stays overdue rather than giving way" do
    card = statement_card(close_day: 10, due_day: 26)
    charge(card.account, Date.new(2026, 9, 20), 300)

    # The statement that closed on 10 October came to $300 and nothing has paid
    # it: the 26th passing does not make the debt go away.
    travel_to Date.new(2026, 10, 27) do
      assert_equal Date.new(2026, 10, 26), card.next_payment_due_date
      assert_equal(-1, card.days_until_due)
    end
  end

  test "a settled statement gives way to the following one once its due date passes" do
    card = statement_card(close_day: 10, due_day: 26)
    charge(card.account, Date.new(2026, 9, 20), 300)
    # Paid after the statement closed but before it fell due.
    charge(card.account, Date.new(2026, 10, 20), -300)

    travel_to Date.new(2026, 10, 27) do
      assert_equal Date.new(2026, 11, 26), card.next_payment_due_date
      assert_equal 30, card.days_until_due
    end
  end

  test "a partly paid statement keeps its due date until it is paid in full" do
    card = statement_card(close_day: 10, due_day: 26)
    charge(card.account, Date.new(2026, 9, 20), 300)
    charge(card.account, Date.new(2026, 10, 20), -100)

    travel_to Date.new(2026, 10, 27) do
      assert_equal Date.new(2026, 10, 26), card.next_payment_due_date
      assert_equal(-1, card.days_until_due)
    end
  end

  test "the last statement balance is everything owed through the close" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account
    as_of = Date.new(2026, 10, 16)

    # The statement that closed on 25 September bills the debt carried in plus
    # this cycle's activity: $1,999 from before the window, $100 charged in it,
    # less the $40 paid in it -- not merely the $60 the window sums to.
    charge_in_window = charge(account, Date.new(2026, 9, 10), 100)
    charge_before_window = charge(account, Date.new(2026, 8, 20), 999)
    charge_on_previous_close = charge(account, Date.new(2026, 8, 25), 1_000)
    payment_in_window = charge(account, Date.new(2026, 9, 20), -40)

    # Charges after the close belong to the statement still building, not this one.
    charge_after_close = charge(account, Date.new(2026, 9, 26), 500)

    assert_equal 2_059, card.last_statement_balance_money(as_of: as_of).amount
    assert_equal "USD", card.last_statement_balance_money(as_of: as_of).currency.iso_code

    assert charge_in_window.persisted?
    assert charge_before_window.persisted?
    assert charge_on_previous_close.persisted?
    assert payment_in_window.persisted?
    assert charge_after_close.persisted?
  end

  test "the balance since the last close counts only what has been charged since" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account
    as_of = Date.new(2026, 10, 16)

    charge(account, Date.new(2026, 9, 10), 100)
    charge(account, Date.new(2026, 9, 26), 500)
    charge(account, Date.new(2026, 10, 3), 20)

    assert_equal 520, card.accrued_since_last_close_money(as_of: as_of).amount
    assert_equal 100, card.last_statement_balance_money(as_of: as_of).amount
  end

  test "a charge on the close day lands on the statement that closes that day" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account
    as_of = Date.new(2026, 10, 16)

    charge(account, Date.new(2026, 9, 25), 70)

    assert_equal 70, card.last_statement_balance_money(as_of: as_of).amount
    assert_equal 0, card.accrued_since_last_close_money(as_of: as_of).amount
  end

  test "a card with no entries in the window has a zero statement, not an unknown one" do
    card = statement_card(close_day: 25, due_day: 5)

    assert_equal 0, card.last_statement_balance_money(as_of: Date.new(2026, 10, 16)).amount
    assert_equal 0, card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16)).amount
  end

  test "pending entries and split parents stay out of the statement, as they do of the balance" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account
    as_of = Date.new(2026, 10, 16)

    charge(account, Date.new(2026, 9, 10), 100)

    pending = charge(account, Date.new(2026, 9, 11), 500)
    Transaction.find(pending.entryable_id).update!(extra: { "plaid" => { "pending" => true } })

    # A split parent is replaced by its children, so the 300 stays in the
    # statement once and the parent row itself never counts.
    parent = charge(account, Date.new(2026, 9, 12), 300)
    [ 200, 100 ].each do |portion|
      account.entries.create!(
        name: "Split portion",
        date: Date.new(2026, 9, 12),
        amount: portion,
        currency: "USD",
        parent_entry: parent,
        entryable: Transaction.new
      )
    end

    assert_equal 400, card.last_statement_balance_money(as_of: as_of).amount
  end

  test "a card with entries in another currency reports no statement rather than a wrong one" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account

    charge(account, Date.new(2026, 9, 10), 100)
    foreign = account.entries.create!(
      name: "Foreign charge",
      date: Date.new(2026, 9, 11),
      amount: 500,
      currency: "EUR",
      entryable: Transaction.new
    )

    assert_nil card.last_statement_balance_money(as_of: Date.new(2026, 10, 16))
    assert_equal 0, card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16)).amount

    foreign.destroy!
    assert_equal 100, card.last_statement_balance_money(as_of: Date.new(2026, 10, 16)).amount
  end

  test "an entry with no currency reports no statement rather than a partial one" do
    card = statement_card(close_day: 25, due_day: 5)
    account = card.account

    charge(account, Date.new(2026, 9, 10), 100)
    before_close = charge(account, Date.new(2026, 9, 11), 500)
    after_close = charge(account, Date.new(2026, 9, 26), 250)
    before_close.update_column(:currency, nil)
    after_close.update_column(:currency, nil)

    # An entry with no currency is one we cannot add up. where.not(currency:)
    # would not match it, so without the refusal it would drop out of the sum
    # and the Overview would quote a partial total as the whole statement.
    assert_nil card.last_statement_balance_money(as_of: Date.new(2026, 10, 16))
    assert_nil card.accrued_since_last_close_money(as_of: Date.new(2026, 10, 16))
  end

  test "the minimum payment shortfall reads against the last statement" do
    travel_to Date.new(2026, 10, 16) do
      card = statement_card(close_day: 25, due_day: 5, minimum_payment: 100)

      charge(card.account, Date.new(2026, 9, 10), 250)
      assert card.minimum_payment_shortfall?

      card.update!(minimum_payment: 500)
      assert_not card.minimum_payment_shortfall?
    end
  end

  test "a card with no minimum payment recorded is not in shortfall" do
    card = statement_card(close_day: 25, due_day: 5, minimum_payment: nil)

    charge(card.account, Date.new(2026, 9, 10), 250)

    assert_not card.minimum_payment_shortfall?
  end

  private
    def statement_card(close_day:, due_day:, minimum_payment: 100)
      card = CreditCard.create!(
        statement_close_day: close_day,
        due_day: due_day,
        minimum_payment: minimum_payment,
        apr: 18.99,
        available_credit: 5_000
      )

      account = Account.create!(
        family: accounts(:credit_card).family,
        name: "Statement Cycle Card",
        balance: 0,
        currency: "USD",
        classification: "liability",
        status: "active",
        accountable: card
      )

      card.reload
    end

    # Positive amount is a charge on a liability; negative is a payment, which
    # is how ForwardCalculator reads a card's entries.
    def charge(account, date, amount)
      account.entries.create!(
        name: "Statement test entry",
        date: date,
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new
      )
    end
end
