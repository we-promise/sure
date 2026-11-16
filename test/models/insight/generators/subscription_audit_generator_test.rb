require "test_helper"

class Insight::Generators::SubscriptionAuditGeneratorTest < ActiveSupport::TestCase
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
end
