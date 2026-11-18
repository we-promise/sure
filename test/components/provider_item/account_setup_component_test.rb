# frozen_string_literal: true

require "test_helper"

class ProviderItem::AccountSetupComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    @item = brex_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    @item.brex_accounts.first.dup.tap { |card| card.update!(account_id: "card_acc_setup", name: "Brex Savings Card", account_kind: "card") }
    @flow = BrexItem::AccountFlow.new(family: @item.family, brex_item: @item)
  end

  test "brex_setup_accounts renders as before" do
    assert_matches_provider_item_snapshot("brex_setup_accounts", render_setup(api_error: nil))
  end

  test "brex_setup_accounts_api_error renders as before" do
    assert_matches_provider_item_snapshot("brex_setup_accounts_api_error", render_setup(api_error: "Unauthorized"))
  end

  test "brex_setup_accounts_all_linked renders as before" do
    assert_matches_provider_item_snapshot("brex_setup_accounts_all_linked", render_setup(api_error: nil, accounts: @item.brex_accounts.none))
  end

  # The dropdowns are DS::Select, which submits through a hidden input, so the
  # field names complete_setup! reads must stay account_types[<id>] and
  # account_subtypes[<id>].
  test "the account type and subtype dropdowns are DS::Select under the provider's field names" do
    page = Nokogiri::HTML5.fragment(render_setup(api_error: nil))
    accounts = @item.brex_accounts.order(:account_id).to_a
    defaults = ApplicationController.helpers.brex_account_setup_defaults(accounts)
    assert_equal %w[CreditCard Depository], defaults.values.map { |d| d[:account_type] }.sort

    assert_empty page.css("select"), "no hand-built select remains"

    accounts.each do |account|
      selector = page.at_css(%([data-controller~="account-type-selector"][data-account-type-selector-account-id-value="#{account.id}"]))
      assert selector, "#{account.name}: has its account type selector"

      type_input = selector.css(%(input[type="hidden"][name="account_types[#{account.id}]"]))
      assert_equal 1, type_input.size, "#{account.name}: one account type input"
      assert type_input.first.ancestors(%([data-controller~="select"])).any?, "#{account.name}: the type input belongs to a DS::Select"
      assert_equal defaults[account.id][:account_type], type_input.first["value"], "#{account.name}: the default type is selected"
      assert selector.at_css(%([data-action~="dropdown:select->account-type-selector#updateSubtype"])), "#{account.name}: choosing a type updates the subtype"

      depository = selector.at_css(%(.subtype-select[data-type="Depository"] input[type="hidden"][name="account_subtypes[#{account.id}]"]))
      assert depository, "#{account.name}: the depository subtype is a DS::Select input"
      assert depository.ancestors(%([data-controller~="select"])).any?
      assert_equal defaults[account.id][:depository_subtype], depository["value"], "#{account.name}: the default depository subtype is selected"
      placeholder = selector.at_css(%(.subtype-select[data-type="Depository"] [role="option"]))
      assert_equal "", placeholder["data-value"], "#{account.name}: the subtype can be left blank"
      assert_equal I18n.t("brex_items.subtype_select.placeholder.subtype"), placeholder["data-filter-name"]

      credit_card = selector.at_css(%(.subtype-select[data-type="CreditCard"]))
      assert_nil credit_card.at_css("input, select"), "#{account.name}: a credit card has no subtype to choose"
    end
  end

  test "the Brex setup page renders through ProviderItem::AccountSetupComponent" do
    ProviderItem::AccountSetupComponent.any_instance.expects(:before_render).once

    render_setup(api_error: nil)
  end

  private
    def render_setup(api_error:, accounts: @item.brex_accounts.order(:account_id))
      ApplicationController.render(
        template: "brex_items/setup_accounts",
        layout: false,
        assigns: {
          brex_item: @item,
          api_error: api_error,
          brex_accounts: accounts,
          account_type_options: @flow.account_type_options,
          displayable_account_type_options: @flow.displayable_account_type_options,
          subtype_options: @flow.subtype_options
        }
      )
    end
end
