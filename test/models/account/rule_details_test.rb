require "test_helper"

class Account::RuleDetailsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2026, 10, 5)
  end

  test "details separate budget transactions from budget cash" do
    account = create_account(Depository, "money_market")
    rows = Account::RuleDetails.new(account, date: @today).rows.index_by(&:key)

    assert_equal "short_term", rows[:liquidity].value
    assert_equal :subtype, rows[:liquidity].source
    assert rows[:counts_in_budget].value
    assert_not rows[:counts_as_budget_cash].value
    assert_nil rows[:release]

    account.update!(liquidity_choice: "immediate")
    rows = Account::RuleDetails.new(account, date: @today).rows.index_by(&:key)

    assert_equal :user, rows[:liquidity].source
    assert rows[:counts_as_budget_cash].value
  end

  private
    def create_account(klass, subtype)
      @family.accounts.create!(
        name: "#{klass.name} #{subtype}",
        balance: 1000,
        currency: "USD",
        accountable: klass.new(subtype: subtype)
      )
    end
end
