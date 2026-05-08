require "test_helper"

class IbkrItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @ibkr_item = ibkr_items(:configured_item)
  end

  test "preload_accounts redirects configured item to setup flow and queues sync" do
    assert_difference "Sync.count", 1 do
      get preload_accounts_ibkr_items_url
    end

    assert_redirected_to setup_accounts_ibkr_item_path(@ibkr_item)
  end

  test "select_existing_account renders available ibkr accounts" do
    get select_existing_account_ibkr_items_url, params: { account_id: accounts(:investment).id }

    assert_response :success
    assert_includes response.body, ibkr_accounts(:main_account).name
  end

  test "complete_account_setup creates investment account and provider link" do
    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post complete_account_setup_ibkr_item_url(@ibkr_item), params: {
          account_ids: [ ibkr_accounts(:main_account).id ]
        }
      end
    end

    created_account = Account.order(created_at: :desc).first
    assert_equal "Investment", created_account.accountable_type
    assert_equal "brokerage", created_account.accountable.subtype
    assert_redirected_to accounts_path

    ibkr_accounts(:main_account).reload
    assert_equal created_account, ibkr_accounts(:main_account).current_account
  end

  test "link_existing_account links manual investment account" do
    account = accounts(:investment)

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_ibkr_items_url, params: {
        account_id: account.id,
        ibkr_account_id: ibkr_accounts(:main_account).id
      }
    end

    assert_redirected_to account_path(account)
    ibkr_accounts(:main_account).reload
    assert_equal account, ibkr_accounts(:main_account).current_account
  end
end
