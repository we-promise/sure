require "test_helper"

class AccountableGroupViewTest < ActionView::TestCase
  include AccountsHelper
  include ApplicationHelper

  setup do
    @user = users(:family_admin)
    Current.stubs(:user).returns(@user)
    @user.stubs(:always_expanded_account_group?).returns(false)
    @eur = accounts(:depository)
    @eur.assign_attributes(name: "Current account", institution_name: "Fineco", currency: "EUR", balance: 100)
    @usd = @eur.dup
    @usd.id = SecureRandom.uuid
    @usd.assign_attributes(currency: "USD", balance: 100)
    @manual = @eur.dup
    @manual.id = SecureRandom.uuid
    @manual.assign_attributes(name: "Cash at home", institution_name: nil, balance: 5)
    @eur.stubs(:converted_balance).returns(100)
    @usd.stubs(:converted_balance).returns(92)
    @manual.stubs(:converted_balance).returns(5)
    controller.request.env["PATH_INFO"] = account_path(@usd)
    classification = BalanceSheet::ClassificationGroup.new(classification: "asset", currency: "EUR", accounts: [])
    @group = BalanceSheet::AccountGroup.new(name: "Cash", color: Depository.color, accountable_type: Depository,
      accounts: [ @eur, @usd, @manual ], classification_group: classification)
  end

  test "renders bank folders with currency labels and opens the active account folder" do
    render partial: "accounts/accountable_group", locals: { account_group: @group }

    assert_select "details[data-institution-group='Fineco'][open]" do
      assert_select "summary", text: /Fineco.*2 accounts.*€192.00/m
      assert_select "a[href='#{account_path(@eur)}']", text: /Cash · EUR/
      assert_select "a[href='#{account_path(@usd)}'][aria-current='page']", text: /Cash · USD/
      assert_select "a[href='#{account_path(@manual)}']", count: 0
    end
    assert_select "a[href='#{account_path(@manual)}']", count: 1
  end

  test "keeps inactive bank folders collapsed and supports mobile rendering" do
    controller.request.env["PATH_INFO"] = "/"

    render partial: "accounts/accountable_group", locals: { account_group: @group, mobile: true, all_tab: true }

    assert_select "#mobile_all_depository details[data-institution-group='Fineco']:not([open])", count: 1
    assert_select "a[aria-current='page']", count: 0
  end
end
