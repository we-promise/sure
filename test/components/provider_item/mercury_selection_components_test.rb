# frozen_string_literal: true

require "test_helper"

class ProviderItem::MercurySelectionComponentsTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    @item = mercury_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    @accounts = [
      { id: "merc_1", nickname: "Ops", name: "Mercury Checking ••1234", status: "active", type: "checking" },
      { id: "merc_2", name: "Mercury Savings & Reserve", status: "active" },
      { id: "merc_3", legalBusinessName: "Example LLC", status: "archived", type: "savings" },
      { id: "merc_4", name: "", status: "active", type: "checking" }
    ]
  end

  test "mercury_select_accounts renders as before" do
    html = render_template("mercury_items/select_accounts", mercury_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: "/accounts")

    assert_matches_provider_item_snapshot("mercury_select_accounts", html)
  end

  test "mercury_select_accounts_without_names renders as before" do
    html = render_template("mercury_items/select_accounts", mercury_item: @item, available_accounts: [ @accounts.last ], accountable_type: "Depository", return_to: nil)

    assert_matches_provider_item_snapshot("mercury_select_accounts_without_names", html)
  end

  test "mercury_select_existing_account renders as before" do
    account = @item.family.accounts.create!(name: "Manual checking", balance: 0, currency: "USD", accountable: Depository.new)
    html = render_template("mercury_items/select_existing_account", mercury_item: @item, available_accounts: @accounts, account: account, return_to: nil)

    assert_matches_provider_item_snapshot("mercury_select_existing_account", html.gsub(account.id, "ACCOUNT"))
  end

  test "mercury_api_error renders as before" do
    html = ApplicationController.render(partial: "mercury_items/api_error", locals: { error_message: "Unauthorized", return_path: "/accounts/new" })

    assert_matches_provider_item_snapshot("mercury_api_error", html)
  end

  test "mercury_setup_required renders as before" do
    assert_matches_provider_item_snapshot("mercury_setup_required", ApplicationController.render(partial: "mercury_items/setup_required"))
  end

  test "the Mercury selection pages and dialogs render through the shared components" do
    [ ProviderItem::AccountSelectionComponent, ProviderItem::ApiErrorComponent, ProviderItem::SetupRequiredComponent ].each do |component|
      component.any_instance.expects(:before_render).at_least_once
    end

    render_template("mercury_items/select_accounts", mercury_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: nil)
    ApplicationController.render(partial: "mercury_items/api_error", locals: { error_message: "x", return_path: nil })
    ApplicationController.render(partial: "mercury_items/setup_required")
  end

  private
    # Mercury's form writes its own authenticity token field, whose
    # attributes put an id between the name and the value.
    def render_template(template, **assigns)
      ApplicationController.render(template: template, assigns: assigns, layout: false)
                           .gsub(/(id="authenticity_token" value=)"[^"]*"/, '\1"CSRF"')
    end
end
