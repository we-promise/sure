require "test_helper"

class UI::AccountPageTest < ViewComponent::TestCase
  test "uses the gold overview and omits statements for physical gold" do
    account = accounts(:investment)
    account.holdings.destroy_all
    account.investment.update!(subtype: "gold", gold_form: "physical")

    component = UI::AccountPage.new(account:)

    assert_equal [ :activity, :overview ], component.tabs
  end

  test "keeps the holdings tab for non-physical investment accounts" do
    component = UI::AccountPage.new(account: accounts(:investment))

    assert_equal [ :activity, :holdings, :statements ], component.tabs
  end

  test "uses holdings for digital gold" do
    account = accounts(:investment)
    account.investment.update!(subtype: "gold", gold_form: "digital")

    assert_equal [ :activity, :holdings, :statements ], UI::AccountPage.new(account:).tabs
  end
end
