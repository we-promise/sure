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
