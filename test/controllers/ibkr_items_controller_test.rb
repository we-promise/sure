require "test_helper"

class IbkrItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @ibkr_item = ibkr_items(:configured_item)
  end

  test "select_existing_account renders available ibkr accounts" do
    get select_existing_account_ibkr_items_url, params: { account_id: accounts(:investment).id }

    assert_response :success
    assert_includes response.body, ibkr_accounts(:main_account).name
  end

  test "create redirects to accounts on success" do
    assert_difference "IbkrItem.count", 1 do
      post ibkr_items_url, params: {
        ibkr_item: {
          query_id: "QUERYNEW",
          token: "TOKENNEW"
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "update redirects to accounts on success" do
    patch ibkr_item_url(@ibkr_item), params: {
      ibkr_item: {
        query_id: "",
        token: ""
      }
    }

    assert_redirected_to accounts_path
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

  test "link_existing_account rejects already linked ibkr account" do
    original_account = accounts(:investment)
    ibkr_account = ibkr_accounts(:main_account)
    AccountProvider.create!(account: original_account, provider: ibkr_account)

    replacement_account = Account.create!(
      family: @ibkr_item.family,
      owner: @user,
      name: "Replacement Brokerage Account",
      balance: 2500,
      cash_balance: 2500,
      currency: "USD",
      accountable: Investment.create!(subtype: "brokerage")
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_ibkr_items_url, params: {
        account_id: replacement_account.id,
        ibkr_account_id: ibkr_account.id
      }
    end

    assert_redirected_to account_path(replacement_account)
    assert_equal "This Interactive Brokers account is already linked.", flash[:alert]
    ibkr_account.reload
    assert_equal original_account, ibkr_account.current_account
  end
end
