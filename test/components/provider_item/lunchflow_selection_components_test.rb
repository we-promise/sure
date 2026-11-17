# frozen_string_literal: true

require "test_helper"

class ProviderItem::LunchflowSelectionComponentsTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  # Lunch Flow's form writes its own authenticity token field, whose
  # attributes put an id between the name and the value.
  AUTHENTICITY_TOKEN = /(id="authenticity_token" value=)"[^"]+"/

  setup do
    @item = lunchflow_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    @accounts = [
      { id: 101, name: "Everyday Checking", institution_name: "Example Bank", iban: "GB33BUKB20201555555555", currency: "GBP", status: "ACTIVE" },
      { id: 102, name: "Joint Savings", institution_name: "Example & Co", currency: "EUR", status: "DISCONNECTED" },
      { id: 103, name: "", institution_name: "Example Bank", currency: "GBP", status: "ACTIVE" }
    ]
  end

  test "lunchflow_select_accounts renders as before" do
    html = render_template("lunchflow_items/select_accounts", lunchflow_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: "/accounts")

    assert_matches_provider_item_snapshot("lunchflow_select_accounts", html)
  end

  test "lunchflow_select_accounts_without_names renders as before" do
    html = render_template("lunchflow_items/select_accounts", lunchflow_item: @item, available_accounts: [ @accounts.last ], accountable_type: "Depository", return_to: nil)

    assert_matches_provider_item_snapshot("lunchflow_select_accounts_without_names", html)
  end

  test "lunchflow_select_existing_account renders as before" do
    account = @item.family.accounts.create!(name: "Manual checking", balance: 0, currency: "USD", accountable: Depository.new)
    html = render_template("lunchflow_items/select_existing_account", lunchflow_item: @item, available_accounts: @accounts, account: account, return_to: nil)

    assert_matches_provider_item_snapshot("lunchflow_select_existing_account", html.gsub(account.id, "ACCOUNT"))
  end

  test "lunchflow_api_error renders as before" do
    html = ApplicationController.render(partial: "lunchflow_items/api_error", locals: { error_message: "Unauthorized", return_path: "/accounts/new" })

    assert_matches_provider_item_snapshot("lunchflow_api_error", html)
  end

  test "lunchflow_setup_required renders as before" do
    assert_matches_provider_item_snapshot("lunchflow_setup_required", ApplicationController.render(partial: "lunchflow_items/setup_required"))
  end

  test "the Lunch Flow selection pages and dialogs render through the shared components" do
    [ ProviderItem::AccountSelectionComponent, ProviderItem::ApiErrorComponent, ProviderItem::SetupRequiredComponent ].each do |component|
      component.any_instance.expects(:before_render).at_least_once
    end

    render_template("lunchflow_items/select_accounts", lunchflow_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: nil)
    ApplicationController.render(partial: "lunchflow_items/api_error", locals: { error_message: "x", return_path: nil })
    ApplicationController.render(partial: "lunchflow_items/setup_required")
  end

  test "the form's own token field treats a blank token as a difference" do
    assert_equal %(id="authenticity_token" value=""), %(id="authenticity_token" value="").gsub(AUTHENTICITY_TOKEN, '\1"CSRF"')
    assert_equal %(id="authenticity_token" value="CSRF"), %(id="authenticity_token" value="abc123").gsub(AUTHENTICITY_TOKEN, '\1"CSRF"')
  end

  private
    def render_template(template, **assigns)
      ApplicationController.render(template: template, assigns: assigns, layout: false)
                           .gsub(AUTHENTICITY_TOKEN, '\1"CSRF"')
    end
end
