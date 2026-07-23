require "test_helper"

class Trading212ItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @item = trading212_items(:configured_item)
  end

  # === create ===

  test "create redirects to accounts on success" do
    assert_difference "Trading212Item.count", 1 do
      post trading212_items_url, params: {
        trading212_item: {
          api_key: "new_api_key",
          api_secret: "new_api_secret",
          environment: "live",
          currency: "USD"
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "create renders error on invalid params" do
    assert_no_difference "Trading212Item.count" do
      post trading212_items_url, params: {
        trading212_item: {
          api_key: "",
          api_secret: "",
          environment: "live"
        }
      }, headers: { "Turbo-Frame" => "modal" }
    end

    assert_response :unprocessable_entity
  end

  # === update ===

  test "update redirects to accounts on success" do
    patch trading212_item_url(@item), params: {
      trading212_item: {
        api_key: "",
        api_secret: "",
        environment: "demo"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "demo", @item.reload.environment
  end

  # === destroy ===

  test "destroy schedules item for deletion" do
    delete trading212_item_url(@item)

    assert_redirected_to settings_providers_path
    assert @item.reload.scheduled_for_deletion?
  end

  # === sync ===

  test "sync triggers sync job" do
    @item.update!(status: :good)
    assert_enqueued_with(job: SyncJob) do
      post sync_trading212_item_url(@item)
    end

    assert_response :redirect
  end

  # === complete_account_setup ===

  test "complete_account_setup creates investment account and provider link" do
    t212_account = trading212_accounts(:main_account)

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post complete_account_setup_trading212_item_url(@item), params: {
          account_ids: [ t212_account.id ]
        }
      end
    end

    created_account = Account.order(created_at: :desc).first
    assert_equal "Investment", created_account.accountable_type
    assert_redirected_to accounts_path

    t212_account.reload
    assert_equal created_account, t212_account.current_account
  end

  test "complete_account_setup returns alert when no accounts selected" do
    post complete_account_setup_trading212_item_url(@item), params: {
      account_ids: []
    }

    assert_redirected_to setup_accounts_trading212_item_path(@item)
    assert_not_nil flash[:alert]
  end

  # === link_existing_account ===

  test "link_existing_account links manual investment account" do
    account = accounts(:investment)

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_trading212_items_url, params: {
        account_id: account.id,
        trading212_account_id: trading212_accounts(:main_account).id
      }
    end

    assert_redirected_to account_path(account)
    trading212_accounts(:main_account).reload
    assert_equal account, trading212_accounts(:main_account).current_account
  end

  test "link_existing_account rejects already linked trading212 account" do
    original_account = accounts(:investment)
    t212_account = trading212_accounts(:main_account)
    AccountProvider.create!(account: original_account, provider: t212_account)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_trading212_items_url, params: {
        account_id: original_account.id,
        trading212_account_id: t212_account.id
      }
    end

    assert_redirected_to account_path(original_account)
  end

  # === select_existing_account ===

  test "select_existing_account renders available trading212 accounts" do
    get select_existing_account_trading212_items_url, params: { account_id: accounts(:investment).id }

    assert_response :success
    assert_includes response.body, trading212_accounts(:main_account).name
  end
end
