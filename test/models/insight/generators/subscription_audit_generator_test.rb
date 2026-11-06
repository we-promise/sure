require "test_helper"

class Insight::Generators::SubscriptionAuditGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @overdue = recurring_transactions(:netflix_subscription)
    @overdue.recurring_occurrences.create!(
      family: @family,
      original_due_on: 50.days.ago.to_date,
      due_on: 50.days.ago.to_date,
      currency: @overdue.currency
    )
  end

  test "generates an insight for an occurrence a full cycle overdue" do
    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_equal 1, insights.size
    assert_equal "subscription_audit:#{@overdue.id}", insights.first.dedup_key
  end

  test "a quarterly bill between its normal occurrences is not nagged about" do
    @overdue.recurring_occurrences.delete_all
    quarterly = @family.recurring_transactions.create!(
      name: "Quarterly water", account: accounts(:depository), amount: 120, currency: "USD",
      expected_day_of_month: 15, anchor_date: 50.days.ago.to_date,
      last_occurrence_date: 50.days.ago.to_date, next_expected_date: 40.days.from_now.to_date,
      status: "active", manual: true
    )
    RecurringTransaction::FrequencyPreset.apply(quarterly, preset: "quarterly", day_of_month: "15")
    quarterly.save!
    quarterly.recurring_occurrences.delete_all
    # 50 days overdue is under one quarterly cycle: normal, not stale.
    quarterly.recurring_occurrences.create!(
      family: @family, original_due_on: 50.days.ago.to_date,
      due_on: 50.days.ago.to_date, currency: "USD"
    )

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_empty insights
  end

  test "returns nothing when recurring transaction detection is disabled" do
    @family.update!(recurring_transactions_disabled: true)

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_empty insights
  end

  test "names the account the subscription is paid from" do
    insight = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate.first

    assert_equal @overdue.account_id, insight.metadata[:account_id]
  end

  test "skips a subscription paid from an account private to one member" do
    @overdue.update_columns(account_id: accounts(:connected).id)

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_empty insights
  end

  test "keeps a subscription that has no account" do
    @overdue.update_columns(account_id: nil)

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_equal [ "subscription_audit:#{@overdue.id}" ], insights.map(&:dedup_key)
    assert_not insights.first.metadata.key?(:account_id)
  end

  test "skips an accountless series whose last-payment amount came from a private account" do
    pay_previous_occurrence_from(accounts(:connected))

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_empty insights
  end

  test "keeps an accountless series whose payments came from shared accounts" do
    pay_previous_occurrence_from(accounts(:depository))

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_equal [ "subscription_audit:#{@overdue.id}" ], insights.map(&:dedup_key)
  end

  test "keeps an accountless fixed-amount series even when a private account paid it" do
    pay_previous_occurrence_from(accounts(:connected))
    @overdue.update_columns(amount_strategy: "fixed")

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_equal [ "subscription_audit:#{@overdue.id}" ], insights.map(&:dedup_key)
  end

  private
    def pay_previous_occurrence_from(account)
      @overdue.update_columns(account_id: nil, amount_strategy: "last")
      entry = create_transaction(account: account, amount: 23.45, date: 80.days.ago.to_date)
      paid = @overdue.recurring_occurrences.create!(
        family: @family, original_due_on: 80.days.ago.to_date, due_on: 80.days.ago.to_date,
        currency: @overdue.currency, status: "paid", closed_at: 80.days.ago, closed_source: "user"
      )
      paid.allocations.create!(allocated_amount: 23.45, currency: @overdue.currency, source: "user_confirmed", entry: entry)
    end
end
