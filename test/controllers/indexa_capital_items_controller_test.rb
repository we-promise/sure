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

  test "the re-rendered panel leaves the API token and password fields empty instead of echoing them" do
    @item.update!(password: "ix-stored-password-7a2d")

    patch indexa_capital_item_url(@item), params: { indexa_capital_item: { name: "Updated Name" } }, as: :turbo_stream

    %w[api_token password].each do |field|
      assert_select "form[action=?] input[name=?]", indexa_capital_item_path(@item), "indexa_capital_item[#{field}]" do |inputs|
        assert_nil inputs.first["value"], "#{field} should not be rendered"
      end
    end
    assert_not_includes response.body, "test_api_token_123"
    assert_not_includes response.body, "ix-stored-password-7a2d"
  end

  test "update with the API token and password left blank keeps both" do
    @item.update!(password: "ix-stored-password-7a2d")

    patch indexa_capital_item_url(@item),
          params: { indexa_capital_item: { name: "Updated Name", api_token: "", password: "" } },
          as: :turbo_stream

    @item.reload
    assert_equal "Updated Name", @item.name
    assert_equal "test_api_token_123", @item.api_token
    assert_equal "ix-stored-password-7a2d", @item.password
  end

  test "update with a new API token replaces only the token" do
    @item.update!(password: "ix-stored-password-7a2d")

    patch indexa_capital_item_url(@item),
          params: { indexa_capital_item: { api_token: "ix-rotated-token", password: "" } },
          as: :turbo_stream

    @item.reload
    assert_equal "ix-rotated-token", @item.api_token
    assert_equal "ix-stored-password-7a2d", @item.password
  end

  test "update with a new password and a blank API token switches to username and password" do
    assert_equal "test_api_token_123", @item.api_token

    patch indexa_capital_item_url(@item),
          params: { indexa_capital_item: { api_token: "", username: "new@example.com", document: "87654321B", password: "ix-new-password" } },
          as: :turbo_stream

    @item.reload
    assert_nil @item.api_token
    assert_equal "ix-new-password", @item.password
    assert_equal "new@example.com", @item.username
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

  test "select accounts leaves the Add Account modal for Settings at the top level" do
    IndexaCapitalItem.any_instance.stubs(:credentials_configured?).returns(false)

    get select_accounts_indexa_capital_items_url, headers: { "Turbo-Frame" => "modal" }

    # A redirect would be followed inside the frame and the flash lost.
    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("indexa_capital_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "setup_accounts does not offer an ignored account" do
    indexa_capital_accounts(:pension_plan).ignore!

    get setup_accounts_indexa_capital_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", indexa_capital_accounts(:mutual_fund).id
    assert_select "input[name='account_ids[]'][value=?]", indexa_capital_accounts(:pension_plan).id, count: 0
  end

  test "complete_account_setup ignores the accounts the user left unchecked" do
    mutual_fund = indexa_capital_accounts(:mutual_fund)
    pension_plan = indexa_capital_accounts(:pension_plan)

    assert_difference "Account.count", 1 do
      post complete_account_setup_indexa_capital_item_url(@item), params: {
        setup_account_ids: [ mutual_fund.id, pension_plan.id ],
        account_ids: [ mutual_fund.id ]
      }
    end

    assert_redirected_to accounts_path
    assert_not_nil mutual_fund.reload.current_account
    assert_not mutual_fund.ignored?
    assert pension_plan.reload.ignored?
    assert_nil pension_plan.current_account
  end

  test "complete_account_setup with every account unchecked ignores them all" do
    ids = [ indexa_capital_accounts(:mutual_fund).id, indexa_capital_accounts(:pension_plan).id ]
    @item.update!(pending_account_setup: true)

    assert_no_difference "Account.count" do
      post complete_account_setup_indexa_capital_item_url(@item), params: { setup_account_ids: ids }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("indexa_capital_items.complete_account_setup.all_skipped"), flash[:notice]
    assert @item.indexa_capital_accounts.where(id: ids).all?(&:ignored?)
    assert_not @item.reload.pending_account_setup?
  end

  test "select accounts does not fetch or refresh an ignored account" do
    pension_plan = indexa_capital_accounts(:pension_plan)
    pension_plan.ignore!
    Provider::IndexaCapital.any_instance.stubs(:list_accounts).returns([
      { account_number: "LPYH3MCQ", name: "Mutual Fund", type: "mutual", status: "active", currency: "EUR" },
      { account_number: "DCU8HWEP", name: "Renamed", type: "pension", status: "active", currency: "EUR" }
    ])
    Provider::IndexaCapital.any_instance.expects(:get_account_balance).with(account_number: "LPYH3MCQ").returns(100)
    Provider::IndexaCapital.any_instance.expects(:get_account_balance).with(account_number: "DCU8HWEP").never

    assert_no_changes -> { pension_plan.reload.attributes } do
      get select_accounts_indexa_capital_items_url
    end

    assert_response :success
    assert_equal 100, indexa_capital_accounts(:mutual_fund).reload.current_balance
  end

  test "linking an ignored account to an existing Sure account stops ignoring it" do
    pension_plan = indexa_capital_accounts(:pension_plan)
    pension_plan.ignore!
    manual_account = Account.create!(family: @family, name: "Manual Pension", balance: 0, currency: "EUR", accountable: Investment.new)

    post link_existing_account_indexa_capital_items_url, params: { account_id: manual_account.id, indexa_capital_account_id: pension_plan.id }

    assert_equal manual_account, pension_plan.reload.current_account
    assert_not pension_plan.ignored?
  end
end
