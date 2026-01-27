require "test_helper"

class Security::PlanRestrictionTrackerTest < ActiveSupport::TestCase
  setup do
    # Use memory store for testing
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "plan_upgrade_required? detects Grow plan message" do
    message = "This endpoint is available starting with Grow subscription."
    assert Security.plan_upgrade_required?(message, provider: "TwelveData")
  end

  test "plan_upgrade_required? detects Pro plan message" do
    message = "API error (code: 400): available starting with Pro plan"
    assert Security.plan_upgrade_required?(message, provider: "TwelveData")
  end

  test "plan_upgrade_required? returns false for other errors" do
    message = "Some other error message"
    assert_not Security.plan_upgrade_required?(message, provider: "TwelveData")
  end

  test "plan_upgrade_required? returns false for nil" do
    assert_not Security.plan_upgrade_required?(nil, provider: "TwelveData")
  end

  test "plan_upgrade_required? returns false for unknown provider" do
    message = "This endpoint is available starting with Grow subscription."
    assert_not Security.plan_upgrade_required?(message, provider: "UnknownProvider")
  end

  test "record_plan_restriction stores restriction in cache" do
    Security.record_plan_restriction(
      security_id: 999,
      error_message: "This endpoint is available starting with Grow subscription.",
      provider: "TwelveData"
    )

    restriction = Security.plan_restriction_for(999, provider: "TwelveData")
    assert_not_nil restriction
    assert_equal "Grow", restriction[:required_plan]
    assert_equal "TwelveData", restriction[:provider]
  end

  test "clear_plan_restriction removes restriction from cache" do
    Security.record_plan_restriction(
      security_id: 999,
      error_message: "available starting with Pro",
      provider: "TwelveData"
    )

    Security.clear_plan_restriction(999, provider: "TwelveData")
    assert_nil Security.plan_restriction_for(999, provider: "TwelveData")
  end

  test "plan_restrictions_for returns multiple restrictions" do
    Security.record_plan_restriction(security_id: 1001, error_message: "available starting with Grow", provider: "TwelveData")
    Security.record_plan_restriction(security_id: 1002, error_message: "available starting with Pro", provider: "TwelveData")

    restrictions = Security.plan_restrictions_for([ 1001, 1002, 9999 ], provider: "TwelveData")

    assert_equal 2, restrictions.keys.count
    assert_equal "Grow", restrictions[1001][:required_plan]
    assert_equal "Pro", restrictions[1002][:required_plan]
    assert_nil restrictions[9999]
  end

  test "plan_restrictions_for returns empty hash for empty input" do
    assert_equal({}, Security.plan_restrictions_for([], provider: "TwelveData"))
    assert_equal({}, Security.plan_restrictions_for(nil, provider: "TwelveData"))
  end

  test "record_plan_restriction does nothing for non-plan errors" do
    Security.record_plan_restriction(
      security_id: 999,
      error_message: "Some other error",
      provider: "TwelveData"
    )

    assert_nil Security.plan_restriction_for(999, provider: "TwelveData")
  end

  test "restrictions are scoped by provider" do
    # Record restriction for TwelveData
    Security.record_plan_restriction(security_id: 999, error_message: "available starting with Grow", provider: "TwelveData")

    # Simulate a different provider by directly writing to cache (tests cache key scoping)
    Rails.cache.write("security_plan_restriction/otherprovider/999", { required_plan: "Pro", provider: "OtherProvider" }, expires_in: 7.days)

    twelve_data_restriction = Security.plan_restriction_for(999, provider: "TwelveData")
    other_restriction = Security.plan_restriction_for(999, provider: "OtherProvider")

    assert_equal "Grow", twelve_data_restriction[:required_plan]
    assert_equal "Pro", other_restriction[:required_plan]
  end

  test "clearing restriction for one provider does not affect another" do
    # Record restriction for TwelveData
    Security.record_plan_restriction(security_id: 999, error_message: "available starting with Grow", provider: "TwelveData")

    # Simulate another provider by directly writing to cache
    Rails.cache.write("security_plan_restriction/otherprovider/999", { required_plan: "Pro", provider: "OtherProvider" }, expires_in: 7.days)

    Security.clear_plan_restriction(999, provider: "TwelveData")

    assert_nil Security.plan_restriction_for(999, provider: "TwelveData")
    assert_not_nil Security.plan_restriction_for(999, provider: "OtherProvider")
  end
end
