# frozen_string_literal: true

require "test_helper"

class ProviderItem::LunchflowAccountSetupComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    @item = lunchflow_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    template = @item.lunchflow_accounts.first
    { "lf_acc_checking" => "Everyday Checking", "lf_acc_savings" => "Joint Savings", "lf_acc_mm" => "Money Market Reserve" }.each do |account_id, name|
      template.dup.tap { |account| account.update!(account_id: account_id, name: name, holdings_supported: false) }
    end
    @flow = LunchflowItem::AccountFlow.new(family: @item.family, item: @item)
  end

  test "lunchflow_setup_accounts renders as before" do
    assert_matches_provider_item_snapshot("lunchflow_setup_accounts", render_setup(api_error: nil))
  end

  test "lunchflow_setup_accounts_api_error renders as before" do
    assert_matches_provider_item_snapshot("lunchflow_setup_accounts_api_error", render_setup(api_error: "Unauthorized"))
  end

  test "lunchflow_setup_accounts_all_linked renders as before" do
    assert_matches_provider_item_snapshot("lunchflow_setup_accounts_all_linked", render_setup(api_error: nil, accounts: @item.lunchflow_accounts.none))
  end

  test "the Lunch Flow setup page renders through ProviderItem::AccountSetupComponent" do
    ProviderItem::AccountSetupComponent.any_instance.expects(:before_render).once

    render_setup(api_error: nil)
  end

  private
    def render_setup(api_error:, accounts: @item.lunchflow_accounts.order(:account_id))
      ApplicationController.render(
        template: "lunchflow_items/setup_accounts",
        layout: false,
        assigns: {
          lunchflow_item: @item,
          api_error: api_error,
          lunchflow_accounts: accounts,
          account_type_options: @flow.account_type_options,
          displayable_account_type_options: @flow.displayable_account_type_options,
          subtype_options: @flow.subtype_options
        }
      )
    end
end
