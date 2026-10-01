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

  test "invalid create outside a frame redirects to the providers page with a 303" do
    assert_no_difference "IndexaCapitalItem.count" do
      post indexa_capital_items_url, params: { indexa_capital_item: { name: "New Connection" } }
    end

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_equal I18n.t("activerecord.errors.models.indexa_capital_item.credentials_required"), flash[:alert]
  end

  test "invalid update outside a frame redirects to the providers page with a 303" do
    patch indexa_capital_item_url(@item), params: { indexa_capital_item: { name: "" } }

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
  end

  # Redirecting back to Bank sync collapses the open connection row.
  test "update from the page re-renders the panel in place" do
    patch indexa_capital_item_url(@item),
          params: { indexa_capital_item: { name: "Updated Name" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "indexa_capital-providers-panel"
    assert_includes response.body, %(id="indexa_capital-providers-panel")
    assert_equal "Updated Name", @item.reload.name
  end

  test "invalid create from the page shows the error in the panel" do
    post indexa_capital_items_url,
         params: { indexa_capital_item: { name: "New Connection" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "indexa_capital-providers-panel"
    assert_includes response.body, ERB::Util.html_escape(I18n.t("activerecord.errors.models.indexa_capital_item.credentials_required"))
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
        account_ids: [ ica.id ]
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
        account_ids: [ ica.id ]
      }
    end
  end

  test "complete_account_setup with no selected accounts redirects to setup" do
    assert_no_difference "Account.count" do
      post complete_account_setup_indexa_capital_item_url(@item), params: {
        account_ids: []
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

  include ProviderLinkAuthorizationTests
  provider_link_authorization_tests(
    select_url: :select_existing_account_indexa_capital_items_url,
    link_url: :link_existing_account_indexa_capital_items_url,
    target: ->(owner) {
      @family.accounts.create!(owner: owner, name: "Manual Fund", balance: 0, currency: "EUR",
                               accountable: Investment.create!)
    },
    provider_account: -> {
      @item.indexa_capital_accounts.create!(name: "Indexa Fund", indexa_capital_account_id: SecureRandom.hex(4),
                                            currency: "EUR", current_balance: 1000)
    },
    provider_param: :indexa_capital_account_id
  )
end
