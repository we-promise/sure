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
