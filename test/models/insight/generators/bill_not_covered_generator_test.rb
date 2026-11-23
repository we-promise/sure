require "test_helper"

class Insight::Generators::BillNotCoveredGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    travel_to Date.new(2026, 11, 16)

    @family = families(:dylan_family)
    # Manual Depository account shared with family_member. Its balance counts
    # as current because it had activity yesterday.
    @checking = accounts(:depository)
    Entry.where(account: @checking).delete_all
    create_transaction(account: @checking, amount: 10, date: 1.day.ago.to_date)
    @checking.update_columns(balance: 1000)
  end

  test "flags a bill the paying account will not cover on its due date" do
    rent = scheduled("Rent", 1460, 7.days.from_now)

    insight = only_insight

    assert_equal "bill_not_covered", insight.insight_type
    assert_equal "high", insight.priority
    assert_equal "bill_not_covered:#{rent.id}", insight.dedup_key
    assert_equal @checking.id, insight.metadata[:account_id]
    assert_equal rent.id, insight.metadata[:recurring_occurrence_id]
    assert_equal "$460.00", insight.facts[:shortfall]
    assert_equal "Checking Account may not cover Rent", insight.title
    assert_equal "Rent of $1,460.00 is due on #{I18n.l(rent.due_on)} from Checking Account. " \
                 "Counting the other bills and income scheduled on that account until then, it will be about $460.00 short.",
      Insight::BodyWriter.new.write(insight)
  end

  test "stays quiet when the balance covers the bill" do
    @checking.update_columns(balance: 1460)
    scheduled("Rent", 1460, 7.days.from_now)

    assert_empty generate
  end

  test "scheduled income into the account before the due date covers the bill" do
    scheduled("Rent", 1460, 7.days.from_now)
    scheduled("Salary", -800, 3.days.from_now)

    assert_empty generate
  end

  test "a scheduled transfer into the account before the due date covers the bill" do
    savings = accounts(:connected)
    AccountShare.create!(account: savings, user: users(:family_member), permission: :read_only)
    scheduled("Rent", 1460, 7.days.from_now)
    scheduled("Top up", 500, 2.days.from_now, account: savings, destination: @checking)

    assert_empty generate
  end

  # The same rule as RecurringTransaction.accessible_by: a series with an
  # endpoint some member cannot open is not theirs to see, in name or amount.
  test "a payment to an account private to one member is not reported" do
    account_shares(:credit_card_shared_with_member).destroy!
    scheduled("Payment to private card", 1460, 7.days.from_now, destination: accounts(:credit_card))

    assert_empty generate

    users(:family_member).update_columns(active: false)
    assert_equal 1, generate.size, "with only the owner active, the card payment is everyone's"
  end

  test "a transfer in from an account private to one member is not counted" do
    rent = scheduled("Rent", 1460, 7.days.from_now)
    scheduled("Top up from private savings", 500, 2.days.from_now, account: accounts(:connected), destination: @checking)

    assert_equal rent.id, only_insight.metadata[:recurring_occurrence_id]
  end

  test "nothing is generated when the family turned recurring transactions off" do
    scheduled("Rent", 1460, 7.days.from_now)
    @family.update!(recurring_transactions_disabled: true)

    assert_empty generate
  end

  test "income due today that has not arrived yet counts" do
    scheduled("Rent", 1460, 3.days.from_now)
    scheduled("Salary", -800, Date.current)

    assert_empty generate
  end

  test "income and the bill on the same day count together" do
    scheduled("Rent", 1460, 3.days.from_now)
    scheduled("Salary", -800, 3.days.from_now)

    assert_empty generate
  end

  test "a payment due today is not counted again: it may already be in the balance" do
    @checking.update_columns(balance: 1500)
    scheduled("Phone", 600, Date.current)
    scheduled("Rent", 1460, 3.days.from_now)

    assert_empty generate
  end

  test "a card payment from checking is a bill" do
    payment = scheduled("Card payment", 1460, 7.days.from_now, destination: accounts(:credit_card))

    assert_equal payment.id, only_insight.metadata[:recurring_occurrence_id]
  end

  test "an occurrence in another currency is skipped" do
    rent = scheduled("Rent", 1460, 7.days.from_now)
    rent.update!(currency: "EUR")

    assert_empty generate
  end

  test "the material metadata does not move with the shortfall, so it is one push per occurrence" do
    rent = scheduled("Rent", 1460, 7.days.from_now)
    before = only_insight

    @checking.update_columns(balance: 600)
    after = only_insight

    assert_equal({ account_id: @checking.id, recurring_occurrence_id: rent.id, due_on: rent.due_on.iso8601 }, after.metadata)
    assert_equal before.metadata, after.metadata
    assert_equal "$860.00", after.facts[:shortfall]
  end

  test "an account in another currency than the family's is left out" do
    @checking.update_columns(currency: "EUR")
    scheduled("Rent", 1460, 7.days.from_now, currency: "EUR")

    assert_empty generate
  end

  test "income that arrives after the due date does not count" do
    scheduled("Rent", 1460, 7.days.from_now)
    scheduled("Salary", -800, 9.days.from_now)

    assert_equal "$460.00", only_insight.facts[:shortfall]
  end

  test "another outflow from the same account before the due date uncovers the bill" do
    @checking.update_columns(balance: 2000)
    scheduled("Phone", 600, 2.days.from_now)
    rent = scheduled("Rent", 1460, 7.days.from_now)

    insight = only_insight

    assert_equal rent.id, insight.metadata[:recurring_occurrence_id]
    assert_equal "$60.00", insight.facts[:shortfall]
  end

  test "outflows from other accounts do not count against this one" do
    @checking.update_columns(balance: 1500)
    scheduled("Rent", 1460, 7.days.from_now)
    scheduled("Phone", 600, 2.days.from_now, account: accounts(:connected))

    assert_empty generate
  end

  test "only what is still owed on a partly paid bill counts" do
    rent = scheduled("Rent", 1460, 7.days.from_now)
    RecurringAllocation.create!(
      recurring_occurrence: rent, state: :confirmed, source: :user_confirmed,
      allocated_amount: 500, currency: "USD", paid_on: Date.current
    )

    assert_empty generate
  end

  test "only the first uncovered bill on an account is reported" do
    first = scheduled("Rent", 1460, 5.days.from_now)
    scheduled("Insurance", 300, 9.days.from_now)

    assert_equal first.id, only_insight.metadata[:recurring_occurrence_id]
  end

  test "bills beyond the horizon are not checked" do
    scheduled("Rent", 1460, (Insight::Generators::BillNotCoveredGenerator::HORIZON_DAYS + 1).days.from_now)

    assert_empty generate
  end

  test "a manual account without recent activity has no balance to trust" do
    Entry.where(account: @checking).delete_all
    create_transaction(account: @checking, amount: 10, date: 20.days.ago.to_date)
    scheduled("Rent", 1460, 7.days.from_now)

    assert_empty generate
  end

  test "a linked account counts only while its synced balance is recent" do
    connected = accounts(:connected)
    AccountShare.create!(account: connected, user: users(:family_member), permission: :full_control)
    Entry.where(account: connected).delete_all
    anchor = create_valuation(account: connected, kind: "current_anchor", amount: 1000, date: 10.days.ago.to_date)
    connected.update_columns(balance: 1000)
    scheduled("Rent", 1460, 7.days.from_now, account: connected)

    assert_empty generate, "a balance last synced ten days ago is stale"

    anchor.update!(date: 1.day.ago.to_date)
    assert_equal connected.id, only_insight.metadata[:account_id]
  end

  test "a credit card is not treated as a paying account" do
    card = accounts(:credit_card)
    create_transaction(account: card, amount: 10, date: 1.day.ago.to_date)
    scheduled("Streaming", 5000, 7.days.from_now, account: card)

    assert_empty generate
  end

  test "an account private to one member is left out of the shared feed" do
    connected = accounts(:connected)
    Entry.where(account: connected).delete_all
    create_valuation(account: connected, kind: "current_anchor", amount: 1000, date: Date.current)
    connected.update_columns(balance: 1000)
    scheduled("Rent", 1460, 7.days.from_now, account: connected)

    assert_empty generate

    users(:family_member).update_columns(active: false)
    assert_equal connected.id, only_insight.metadata[:account_id], "an inactive member does not hide an account"
  end

  private
    def generate
      Insight::Generators::BillNotCoveredGenerator.new(@family).generate
    end

    def only_insight
      insights = generate
      assert_equal 1, insights.size, "expected exactly one insight, got #{insights.map(&:dedup_key)}"
      insights.first
    end

    # One active series with exactly one open occurrence on `due`. Positive
    # amounts leave `account`, negative ones arrive in it; a destination makes
    # it a transfer into that account.
    def scheduled(name, amount, due, account: @checking, destination: nil, currency: "USD")
      due = due.to_date
      series = @family.recurring_transactions.create!(
        name: name, account: account, destination_account: destination, amount: amount, currency: currency,
        expected_day_of_month: due.day, last_occurrence_date: due << 1, next_expected_date: due,
        status: "active", manual: true
      )
      series.recurring_occurrences.delete_all
      series.recurring_occurrences.create!(family: @family, original_due_on: due, due_on: due, currency: currency)
    end
end
