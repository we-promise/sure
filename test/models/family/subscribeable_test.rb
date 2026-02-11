require "test_helper"

class Family::SubscribeableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # We keep the status eventually consistent, but don't rely on it for guarding the app
  test "trial respects end date even if status is not yet updated" do
    @family.subscription.update!(trial_ends_at: 1.day.ago, status: "trialing")
    assert_not @family.trialing?
  end

  test "can_manage_subscription? returns true when stripe_customer_id is present" do
    @family.update!(stripe_customer_id: "cus_test123")
    assert @family.can_manage_subscription?
  end

  test "can_manage_subscription? returns false when stripe_customer_id is nil" do
    @family.update!(stripe_customer_id: nil)
    assert_not @family.can_manage_subscription?
  end

  test "can_manage_subscription? returns false when stripe_customer_id is blank" do
    @family.update!(stripe_customer_id: "")
    assert_not @family.can_manage_subscription?
  end
end
