require "test_helper"

class AccountableSparklineTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @owner = users(:family_admin)
    @co_owner = users(:family_member)
    @account = accounts(:depository)
  end

  teardown { Current.session = nil }

  test "version changes when the owner's percentage changes" do
    before = version_for(@owner)

    @account.update!(ownership_percentage: 60)

    assert_not_equal before, version_for(@owner)
  end

  test "version changes when a co-owner's percentage changes" do
    before = version_for(@co_owner)

    @account.account_shares.find_by!(user: @co_owner).update!(ownership_percentage: 40)

    assert_not_equal before, version_for(@co_owner)
  end

  test "the batched versions match the version of a single group" do
    @account.update!(ownership_percentage: 60)
    sign_in(@owner)

    batched = AccountableSparkline.versions([ Depository ])[Depository]

    assert_equal AccountableSparkline.new(Depository).version, batched
  end

  test "versions differ for viewers with different percentages" do
    @account.update!(ownership_percentage: 60)
    @account.account_shares.find_by!(user: @co_owner).update!(ownership_percentage: 40)

    assert_not_equal version_for(@owner), version_for(@co_owner)
  end

  test "a linked investment group is scaled to the viewer's share too" do
    investment = accounts(:investment)
    AccountProvider.create!(account: investment, provider: snaptrade_accounts(:fidelity_401k))
    investment.balances.destroy_all
    create_balance(account: investment, date: Date.current, balance: 1_000)
    sign_in(@owner)

    full = AccountableSparkline.new(Investment).series.values.last.value.amount
    investment.update!(ownership_percentage: 50)
    half = AccountableSparkline.new(Investment).series.values.last.value.amount

    assert_in_delta 500, full - half, 0.01
  end

  private
    def sign_in(user)
      Current.session = user.sessions.create!
    end

    def version_for(user)
      sign_in(user)
      AccountableSparkline.new(Depository).version
    end
end
