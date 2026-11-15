# frozen_string_literal: true

require "test_helper"

class ProviderItem::SelectionComponentsTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    @item = brex_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    @accounts = [
      { id: "cash_acc_1", name: "Brex Operating", account_kind: "cash", current_balance: { amount: 125_000, currency: "USD" }, status: "ACTIVE" },
      { id: "card_acc_1", name: "", account_kind: "card", status: "ACTIVE" }
    ]
  end

  test "brex_select_accounts renders as before" do
    html = render_template("brex_items/select_accounts", brex_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: "/accounts")

    assert_matches_provider_item_snapshot("brex_select_accounts", html)
  end

  test "brex_select_accounts_without_names renders as before" do
    BrexAccount.stubs(:name_for).returns("")
    html = render_template("brex_items/select_accounts", brex_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: nil)

    assert_matches_provider_item_snapshot("brex_select_accounts_without_names", html)
  end

  test "brex_select_existing_account renders as before" do
    account = @item.family.accounts.create!(name: "Manual checking", balance: 0, currency: "USD", accountable: Depository.new)
    html = render_template("brex_items/select_existing_account", brex_item: @item, available_accounts: @accounts, account: account, return_to: nil)

    assert_matches_provider_item_snapshot("brex_select_existing_account", html.gsub(account.id, "ACCOUNT"))
  end

  test "brex_api_error renders as before" do
    html = ApplicationController.render(partial: "brex_items/api_error", locals: { error_message: "Unauthorized", return_path: "/accounts/new" })

    assert_matches_provider_item_snapshot("brex_api_error", html)
  end

  test "brex_setup_required renders as before" do
    assert_matches_provider_item_snapshot("brex_setup_required", ApplicationController.render(partial: "brex_items/setup_required"))
  end

  test "the Brex selection pages and dialogs render through the shared components" do
    [ ProviderItem::AccountSelectionComponent, ProviderItem::ApiErrorComponent, ProviderItem::SetupRequiredComponent ].each do |component|
      component.any_instance.expects(:before_render).at_least_once
    end

    render_template("brex_items/select_accounts", brex_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: nil)
    ApplicationController.render(partial: "brex_items/api_error", locals: { error_message: "x", return_path: nil })
    ApplicationController.render(partial: "brex_items/setup_required")
  end

  private
    def render_template(template, **assigns)
      ApplicationController.render(template: template, assigns: assigns, layout: false)
    end
end
