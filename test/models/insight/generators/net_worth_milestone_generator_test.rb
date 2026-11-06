require "test_helper"

class Insight::Generators::NetWorthMilestoneGeneratorTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:dylan_family)
    @period = Period.last_30_days
    Balance.where(account: @family.accounts).delete_all

    # `depository` is shared with family_member; `connected` is private to
    # family_admin. Together they cross 10,000, the shared one alone does not.
    create_balance(account: accounts(:depository), date: @period.start_date, balance: 9_000)
    create_balance(account: accounts(:depository), date: @period.end_date, balance: 9_500)
    create_balance(account: accounts(:connected), date: @period.start_date, balance: 0)
    create_balance(account: accounts(:connected), date: @period.end_date, balance: 2_000)
  end

  test "a private account does not push the shared net worth over a milestone" do
    assert_empty generate
  end

  test "counts every account once the only other member is inactive" do
    users(:family_member).update_columns(active: false)

    assert_equal [ "net_worth_milestone:10000" ], generate.map(&:dedup_key)
  end

  private
    def generate
      Insight::Generators::NetWorthMilestoneGenerator.new(@family).generate
    end
end
