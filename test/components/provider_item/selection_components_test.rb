# frozen_string_literal: true

require "test_helper"

class ProviderItem::SelectionComponentsTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    @item = brex_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    # The new-account dialogs name the product; pin it so a PRODUCT_NAME set
    # in the environment does not change the snapshots.
    Rails.configuration.x.stubs(:product_name).returns("Sure")
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

  # One account named, one not: the named one stays selectable.
  test "brex_select_accounts_mixed_names renders as before" do
    BrexAccount.stubs(:name_for).returns("Brex Operating")
    BrexAccount.stubs(:name_for).with { |data| data[:id] == "card_acc_1" }.returns("")
    html = render_template("brex_items/select_accounts", brex_item: @item, available_accounts: @accounts, accountable_type: "Depository", return_to: nil)

    assert_matches_provider_item_snapshot("brex_select_accounts_mixed_names", html)
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

  # Snapshot normalising drops the space between a label and its text, so check
  # each troubleshooting item's visible text on the raw render.
  test "the API error dialog keeps a space between each issue and its fix" do
    html = ApplicationController.render(partial: "brex_items/api_error", locals: { error_message: "Unauthorized", return_path: nil })
    items = Nokogiri::HTML.fragment(html).css("li").map { |item| item.text.squish }

    assert_includes items, "#{I18n.t("brex_items.api_error.invalid_token_label")} #{I18n.t("brex_items.api_error.invalid_token")}"
    assert_equal 5, items.count { |item| item.match?(/: \S/) }
  end

  test "the API error dialog links to provider settings when there is no return path" do
    html = ApplicationController.render(partial: "brex_items/api_error", locals: { error_message: "Unauthorized", return_path: nil })

    assert_includes html, %(href="#{Rails.application.routes.url_helpers.settings_providers_path}")
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
