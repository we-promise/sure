require "test_helper"

class Insight::Generators::SubscriptionAuditGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @overdue = recurring_transactions(:netflix_subscription)
    @overdue.update!(next_expected_date: 50.days.ago.to_date)
  end

  test "generates an insight for an overdue recurring transaction" do
    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_equal 1, insights.size
    assert_equal "subscription_audit:#{@overdue.id}", insights.first.dedup_key
  end

  test "returns nothing when recurring transaction detection is disabled" do
    @family.update!(recurring_transactions_disabled: true)

    insights = Insight::Generators::SubscriptionAuditGenerator.new(@family).generate

    assert_empty insights
  end
end
