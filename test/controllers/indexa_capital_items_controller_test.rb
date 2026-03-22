# frozen_string_literal: true

require "test_helper"

class IndexaCapitalItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = indexa_capital_items(:configured_with_token)
  end

  test "should create indexa_capital_item with api_token" do
    assert_difference("IndexaCapitalItem.count", 1) do
      post indexa_capital_items_url, params: {
        indexa_capital_item: { name: "New Connection", api_token: "new_token" }
      }
    end

    assert_redirected_to settings_providers_path
  end

  test "should update indexa_capital_item" do
    patch indexa_capital_item_url(@item), params: {
      indexa_capital_item: { name: "Updated Name" }
    }

    assert_redirected_to settings_providers_path
    @item.reload
    assert_equal "Updated Name", @item.name
  end

  test "should destroy indexa_capital_item" do
    assert_difference("IndexaCapitalItem.count", 0) do # doesn't delete immediately
      delete indexa_capital_item_url(@item)
    end

    assert_redirected_to settings_providers_path
    @item.reload
    assert @item.scheduled_for_deletion?
  end

  test "should sync indexa_capital_item" do
    post sync_indexa_capital_item_url(@item)
    assert_response :redirect
  end

  test "should show setup_accounts page" do
    get setup_accounts_indexa_capital_item_url(@item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected indexa_capital_accounts" do
    ica = indexa_capital_accounts(:mutual_fund)

    assert_difference "Account.count", 1 do
      post complete_account_setup_indexa_capital_item_url(@item), params: {
        accounts: {
          ica.id => { account_type: "investment", subtype: "brokerage" }
        }
      }
    end

    assert_response :redirect
    ica.reload
    assert_not_nil ica.current_account
    assert_equal "Investment", ica.current_account.accountable_type
  end

  test "complete_account_setup skips already linked accounts" do
    ica = indexa_capital_accounts(:mutual_fund)

    # Pre-link
    account = Account.create!(
      family: @family, name: "Existing Fund", balance: 1000, currency: "EUR",
      accountable: Investment.new
    )
    AccountProvider.create!(account: account, provider: ica)

    assert_no_difference "Account.count" do
      post complete_account_setup_indexa_capital_item_url(@item), params: {
        accounts: {
          ica.id => { account_type: "investment" }
        }
      }
    end
  end

  test "complete_account_setup with all skipped redirects to setup" do
    ica = indexa_capital_accounts(:mutual_fund)

    assert_no_difference "Account.count" do
      post complete_account_setup_indexa_capital_item_url(@item), params: {
        accounts: {
          ica.id => { account_type: "skip" }
        }
      }
    end

    assert_redirected_to setup_accounts_indexa_capital_item_path(@item)
  end

  test "cannot access other family's indexa_capital_item" do
    other_item = indexa_capital_items(:configured_with_credentials)

    get setup_accounts_indexa_capital_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to indexa_capital_account" do
    manual_account = Account.create!(
      family: @family, name: "Manual Investment", balance: 0, currency: "EUR",
      accountable: Investment.new
    )

    ica = indexa_capital_accounts(:pension_plan)

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_indexa_capital_items_url, params: {
        account_id: manual_account.id,
        indexa_capital_account_id: ica.id
      }
    end

    ica.reload
    assert_equal manual_account, ica.current_account
  end

  test "link_existing_account rejects already linked provider account" do
    ica = indexa_capital_accounts(:mutual_fund)

    # Pre-link
    account = Account.create!(
      family: @family, name: "Linked Fund", balance: 1000, currency: "EUR",
      accountable: Investment.new
    )
    AccountProvider.create!(account: account, provider: ica)

    target_account = Account.create!(
      family: @family, name: "Target", balance: 0, currency: "EUR",
      accountable: Investment.new
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_indexa_capital_items_url, params: {
        account_id: target_account.id,
        indexa_capital_account_id: ica.id
      }
    end
  end
end
