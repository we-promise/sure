require "test_helper"

class TransactionExclusionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "should be valid with required attributes" do
    exclusion = TransactionExclusion.new(
      family: @family,
      external_id: "test_external_123",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    assert exclusion.valid?
  end

  test "should require family" do
    exclusion = TransactionExclusion.new(family: nil)
    assert_not exclusion.valid?
    assert_includes exclusion.errors[:family], "must exist"
  end

  test "should require external_id presence" do
    exclusion = TransactionExclusion.new(
      family: @family,
      external_id: nil,
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    assert_not exclusion.valid?
    assert_includes exclusion.errors[:external_id], "can't be blank"
  end

  test "should require provider presence" do
    exclusion = TransactionExclusion.new(
      family: @family,
      external_id: "test_123",
      provider: nil,
      exclusion_reason: "merged"
    )
    assert_not exclusion.valid?
    assert_includes exclusion.errors[:provider], "can't be blank"
  end

  test "should require exclusion_reason presence" do
    exclusion = TransactionExclusion.new(
      family: @family,
      external_id: "test_123",
      provider: "enable_banking",
      exclusion_reason: nil
    )
    assert_not exclusion.valid?
    assert_includes exclusion.errors[:exclusion_reason], "can't be blank"
  end

  test "should validate uniqueness of external_id scoped to family and provider" do
    TransactionExclusion.create!(
      family: @family,
      external_id: "unique_123",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )

    duplicate = TransactionExclusion.new(
      family: @family,
      external_id: "unique_123",
      provider: "enable_banking",
      exclusion_reason: "dismissed"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:external_id], "has already been taken"
  end

  test "should allow same external_id across different providers" do
    TransactionExclusion.create!(
      family: @family,
      external_id: "shared_id",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )

    second = TransactionExclusion.new(
      family: @family,
      external_id: "shared_id",
      provider: "plaid",
      exclusion_reason: "merged"
    )
    assert second.valid?
  end

  test "should allow same external_id across different families" do
    other_family = families(:empty)

    TransactionExclusion.create!(
      family: @family,
      external_id: "shared_id",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )

    second = TransactionExclusion.new(
      family: other_family,
      external_id: "shared_id",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    assert second.valid?
  end

  test "enum should include merged, dismissed, excluded" do
    assert_includes TransactionExclusion.exclusion_reasons.keys, "merged"
    assert_includes TransactionExclusion.exclusion_reasons.keys, "dismissed"
    assert_includes TransactionExclusion.exclusion_reasons.keys, "excluded"
  end

  test "enum values should be accessible" do
    assert_equal "merged", TransactionExclusion.exclusion_reasons["merged"]
    assert_equal "dismissed", TransactionExclusion.exclusion_reasons["dismissed"]
    assert_equal "excluded", TransactionExclusion.exclusion_reasons["excluded"]
  end

  test "should belong to family" do
    exclusion = TransactionExclusion.new(
      family: @family,
      external_id: "test",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    assert_equal @family, exclusion.family
  end

  test "scope for_provider should filter by provider" do
    enable_banking_exclusion = TransactionExclusion.create!(
      family: @family,
      external_id: "enable_123",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    plaid_exclusion = TransactionExclusion.create!(
      family: @family,
      external_id: "plaid_123",
      provider: "plaid",
      exclusion_reason: "merged"
    )

    enable_banking_results = TransactionExclusion.for_provider("enable_banking")
    assert_includes enable_banking_results, enable_banking_exclusion
    assert_not_includes enable_banking_results, plaid_exclusion

    plaid_results = TransactionExclusion.for_provider("plaid")
    assert_includes plaid_results, plaid_exclusion
    assert_not_includes plaid_results, enable_banking_exclusion
  end

  test "scope for_external_ids should filter by list of ids" do
    exclusion1 = TransactionExclusion.create!(
      family: @family,
      external_id: "ext_1",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    exclusion2 = TransactionExclusion.create!(
      family: @family,
      external_id: "ext_2",
      provider: "enable_banking",
      exclusion_reason: "merged"
    )
    exclusion3 = TransactionExclusion.create!(
      family: @family,
      external_id: "ext_3",
      provider: "plaid",
      exclusion_reason: "merged"
    )

    results = TransactionExclusion.for_external_ids(["ext_1", "ext_2"])
    assert_includes results, exclusion1
    assert_includes results, exclusion2
    assert_not_includes results, exclusion3
   end

  test "association should have dependent: :destroy" do
    reflection = Family.reflect_on_association(:transaction_exclusions)
    assert_equal :destroy, reflection.options[:dependent]
  end
end
