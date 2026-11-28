# frozen_string_literal: true

require "test_helper"

class ProviderItem::MercuryAccountSetupComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    @item = mercury_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    template = @item.mercury_accounts.first
    { "merc_acc_savings" => "Mercury Savings", "merc_acc_mm" => "Treasury MM", "merc_acc_ops" => "Operating" }.each do |account_id, name|
      template.dup.tap { |account| account.update!(account_id: account_id, name: name) }
    end
    @flow = MercuryItem::AccountFlow.new(family: @item.family, item: @item)
  end

  test "mercury_setup_accounts renders as before" do
    assert_matches_provider_item_snapshot("mercury_setup_accounts", render_setup(api_error: nil))
  end

  test "mercury_setup_accounts_api_error renders as before" do
    assert_matches_provider_item_snapshot("mercury_setup_accounts_api_error", render_setup(api_error: "Unauthorized"))
  end

  test "mercury_setup_accounts_all_linked renders as before" do
    assert_matches_provider_item_snapshot("mercury_setup_accounts_all_linked", render_setup(api_error: nil, accounts: @item.mercury_accounts.none))
  end

  test "the Mercury setup page renders through ProviderItem::AccountSetupComponent" do
    ProviderItem::AccountSetupComponent.any_instance.expects(:before_render).once

    render_setup(api_error: nil)
  end

  private
    def render_setup(api_error:, accounts: @item.mercury_accounts.order(:account_id))
      ApplicationController.render(
        template: "mercury_items/setup_accounts",
        layout: false,
        assigns: {
          mercury_item: @item,
          api_error: api_error,
          mercury_accounts: accounts,
          account_type_options: @flow.account_type_options,
          displayable_account_type_options: @flow.displayable_account_type_options,
          subtype_options: @flow.subtype_options
        }
      )
    end
end
