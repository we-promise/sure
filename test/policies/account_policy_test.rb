# frozen_string_literal: true

require "test_helper"

class AccountPolicyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @account = @owner.family.accounts.create!(
      name: "Policy Checking", owner: @owner, balance: 100, currency: "USD", accountable: Depository.new
    )
  end

  test "owner may update and annotate" do
    assert_tiers @owner, update: true, annotate: true
  end

  test "full_control may update and annotate" do
    share("full_control")
    assert_tiers @member, update: true, annotate: true
  end

  test "read_write may annotate but not update" do
    share("read_write")
    assert_tiers @member, update: false, annotate: true
  end

  test "read_only may do neither" do
    share("read_only")
    assert_tiers @member, update: false, annotate: false
  end

  test "a user with no share may do neither" do
    assert_tiers @member, update: false, annotate: false
  end

  test "permits? maps levels onto the tier predicates" do
    assert AccountPolicy.new(@owner, @account).permits?(:owner)
    assert AccountPolicy.new(@owner, @account).permits?(:write)

    share("full_control")
    policy = AccountPolicy.new(@member, @account)
    assert policy.permits?(:write)
    assert policy.permits?(:annotate)
    assert_not policy.permits?(:owner), ":owner is owner-only, even for full_control"

    assert_not policy.permits?(:bogus), "unknown levels are denied"
    assert_not policy.permits?("write"), "levels are symbols; a string is denied"
  end

  private

    def share(permission)
      @account.account_shares.create!(user: @member, permission: permission, include_in_finances: true)
    end

    def assert_tiers(user, update:, annotate:)
      policy = AccountPolicy.new(user, @account)
      assert_equal update, policy.update?, "update?"
      assert_equal annotate, policy.annotate?, "annotate?"
    end
end
