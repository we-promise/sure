require "test_helper"

class UI::Account::ActivityDateTest < ViewComponent::TestCase
  setup do
    Current.session = sessions(:one)
  end

  test "shows the projected balance and marks it as such for a scheduled date" do
    account = accounts(:depository)
    projected = Money.new(5300, account.currency)

    data = Account::ActivityFeedData::ActivityDateData.new(
      date: Date.current + 5.days,
      entries: [],
      balance: nil,
      projected_balance_money: projected,
      transfers: [],
      split_parents: {}
    )

    component = UI::Account::ActivityDate.new(account: account, data: data)

    assert_equal projected, component.end_balance_money
    assert component.projected?

    render_inline(component)

    # Guards against translations silently missing under the wrong i18n
    # scope -- a missing key renders humanized text wrapped in a
    # "translation_missing" span, which also breaks DS::Pill's `title`
    # attribute since it falls back to the (HTML-safe) label.
    assert_no_selector ".translation_missing"
    assert_text "Projected"
    assert_text projected.format
  end

  test "falls back to zero when neither a Balance row nor a projection exists" do
    account = accounts(:depository)

    data = Account::ActivityFeedData::ActivityDateData.new(
      date: Date.current,
      entries: [],
      balance: nil,
      projected_balance_money: nil,
      transfers: [],
      split_parents: {}
    )

    component = UI::Account::ActivityDate.new(account: account, data: data)

    assert_equal Money.new(0, account.currency), component.end_balance_money
    refute component.projected?

    render_inline(component)

    assert_no_selector ".translation_missing"
    assert_text "No balance data available for this date"
  end

  test "uses the date's own Balance row when one exists, even if a projection was computed" do
    account = accounts(:depository)
    balance = balances(:one)

    data = Account::ActivityFeedData::ActivityDateData.new(
      date: balance.date,
      entries: [],
      balance: balance,
      projected_balance_money: nil,
      transfers: [],
      split_parents: {}
    )

    component = UI::Account::ActivityDate.new(account: account, data: data)

    assert_equal balance.end_balance_money, component.end_balance_money
    refute component.projected?

    render_inline(component)

    assert_no_selector ".translation_missing"
  end
end
