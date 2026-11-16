require "test_helper"

class Insight::Generators::NetWorthMilestoneGeneratorTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    Balance.where(account: @family.accounts).delete_all
  end

  test "celebrates a milestone crossed upwards within the last 30 days" do
    net_worth 60 => 240_000, 10 => 255_000

    assert_equal [ "net_worth_milestone:250000" ], dedup_keys
  end

  test "celebrates only the highest milestone when several are crossed at once" do
    net_worth 60 => 90_000, 5 => 263_000

    assert_equal [ "net_worth_milestone:250000" ], dedup_keys
  end

  test "stays quiet when net worth went down" do
    net_worth 60 => 255_000, 10 => 240_000

    assert_empty dedup_keys
  end

  test "a drop below a milestone does not celebrate a lower one passed earlier" do
    net_worth 60 => 90_000, 20 => 263_000, 2 => 244_000

    assert_empty dedup_keys
  end

  test "a recovery above a milestone shortly after a dip does not celebrate it again" do
    net_worth 60 => 240_000, 20 => 255_000, 10 => 248_000, 3 => 252_000

    assert_empty dedup_keys
  end

  test "a recovery after a dip that started before the window does not celebrate it again" do
    net_worth 60 => 255_000, 33 => 245_000, 5 => 252_000

    assert_empty dedup_keys
  end

  test "celebrates a milestone regained after a full window below it" do
    net_worth 60 => 255_000, 45 => 245_000, 5 => 252_000

    assert_equal [ "net_worth_milestone:250000" ], dedup_keys
  end

  test "a higher milestone reached before the window does not hide one regained inside it" do
    net_worth 60 => 510_000, 40 => 245_000, 2 => 252_000

    assert_equal [ "net_worth_milestone:250000" ], dedup_keys
  end

  test "a milestone crossed before the window is no longer news" do
    net_worth 60 => 240_000, 35 => 255_000

    assert_empty dedup_keys
  end

  private
    # Sets the family's net worth from N days ago onwards; each value holds
    # until the next one.
    def net_worth(values_by_days_ago)
      values_by_days_ago.each do |days_ago, amount|
        create_balance(account: @account, date: days_ago.days.ago.to_date, balance: amount)
      end
    end

    def dedup_keys
      Insight::Generators::NetWorthMilestoneGenerator.new(@family).generate.map(&:dedup_key)
    end
end
