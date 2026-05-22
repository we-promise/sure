require "test_helper"

class AkahuItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Main Akahu",
      app_token: "app-token",
      user_token: "user-token"
    )
    @akahu_account = @akahu_item.akahu_accounts.create!(
      name: "Akahu Checking",
      account_id: "acc_123",
      currency: "NZD"
    )
    @account = accounts(:depository)
  end

  test "setup_accounts preselects mapped account type for each account" do
    AkahuItemsController.any_instance.stubs(:fetch_akahu_accounts_from_api).returns(nil)

    @akahu_account.update!(account_type: "SAVINGS")
    get setup_accounts_akahu_item_url(@akahu_item)
    assert_response :success

    selected_option = css_select("select[name='account_types[#{@akahu_account.id}]'] option[selected='selected']").first
    assert_equal "Depository", selected_option["value"]

    @akahu_account.update!(account_type: "FOREIGN")
    get setup_accounts_akahu_item_url(@akahu_item)
    assert_response :success
    selected_option = css_select("select[name='account_types[#{@akahu_account.id}]'] option[selected='selected']").first
    assert_equal "skip", selected_option["value"]
  end

  test "complete_account_setup uses Akahu account type suggestion subtype for investment accounts" do
    @akahu_account.update!(account_type: "KIWISAVER")

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post complete_account_setup_akahu_item_url(@akahu_item), params: {
          account_types: { @akahu_account.id.to_s => "Investment" }
        }
      end
    end

    assert_redirected_to accounts_path
    @akahu_account.reload
    created_account = @akahu_account.current_account
    assert_not_nil created_account
    assert_equal "Investment", created_account.accountable_type
    assert_equal "retirement", created_account.accountable.subtype
  end

  test "link existing account rejects protocol-relative return paths" do
    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_akahu_items_url, params: {
        account_id: @account.id,
        akahu_item_id: @akahu_item.id,
        akahu_account_id: @akahu_account.id,
        return_to: "//evil.example/accounts"
      }
    end

    assert_redirected_to accounts_path
  end
end
