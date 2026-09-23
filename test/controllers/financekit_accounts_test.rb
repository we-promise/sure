require "test_helper"
require_relative "../support/financekit_test_helper"

class FinancekitAccountsTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper
  include ActionView::RecordIdentifier

  setup do
    ensure_tailwind_build
    financekit_setup(user: users(:empty))
    sign_in @user
  end

  test "a family with only FinanceKit accounts sees them on the accounts index" do
    get accounts_url

    assert_response :success
    assert_select "#financekit-accounts" do
      assert_select "summary", text: /Apple Wallet/
      assert_select "a[href=?][data-turbo-frame='_top']", account_path(@source.account), text: "Test Wallet"
      assert_select "turbo-frame##{dom_id(@source.account)}"
    end
    assert_select "#manual-accounts a[href=?]", account_path(@source.account), count: 0
  end

  test "FinanceKit account detail renders imported transactions" do
    accept_and_apply

    get account_url(@source.account)

    assert_response :success
    assert_select "header h2", text: "Test Wallet"
    assert_includes response.body, "Synthetic shop"
  end

  test "Wallet accounts cannot use generic unlink controls or endpoints" do
    account = @source.account
    provider = account.account_providers.sole
    credential_digest = @item.credential_digest

    get accounts_url
    assert_response :success
    assert_select "a[href=?]", confirm_unlink_account_path(account), count: 0
    assert_select "a[href=?]", select_provider_account_path(account), count: 0

    get confirm_unlink_account_url(account)
    assert_redirected_to account_url(account)
    assert_equal I18n.t("accounts.unlink.managed_in_app"), flash[:alert]

    assert_no_difference [ "AccountProvider.count", "FinancekitAccount.count" ] do
      delete unlink_account_url(account)
    end
    assert_redirected_to account_url(account)
    assert_equal I18n.t("accounts.unlink.managed_in_app"), flash[:alert]
    assert_equal provider, account.reload.account_providers.sole
    assert_equal "active", @item.reload.status
    assert_equal credential_digest, @item.credential_digest
    accept_and_apply
    assert account.entries.exists?(name: "Synthetic shop")
  end

  test "index shows disabled Wallet accounts but excludes pending deletion" do
    @source.account.update!(status: "disabled")
    get accounts_url
    assert_response :success
    assert_select "#financekit-accounts a[href=?]", account_path(@source.account)

    @source.account.update!(status: "pending_deletion")
    get accounts_url
    assert_response :success
    assert_select "#financekit-accounts", count: 0
  end

  test "index limits Wallet accounts to the viewer's owned and shared accounts" do
    private_source_id = SecureRandom.uuid
    @item.update!(status: "repair_required", consent: @item.consent.merge(
      "selected_source_account_ids" => [ @source_id, private_source_id ]))
    private_mapping = FinancekitAccount.map!(@item, private_source_id, @mapping_input.merge("name" => "Private Wallet"))
    @item.activate!
    shared = @source.account
    [ shared, private_mapping.account ].each { |account| account.account_shares.destroy_all }
    viewer = users(:new_email)
    assert_equal @family, viewer.family
    shared.account_shares.create!(user: viewer, permission: "read_only")

    sign_in viewer
    get accounts_url

    assert_response :success
    assert_select "#financekit-accounts a[href=?]", account_path(shared)
    assert_select "#financekit-accounts a[href=?]", account_path(private_mapping.account), count: 0
    assert_not_includes response.body, "Private Wallet"

    sign_in users(:family_admin)
    get accounts_url
    assert_response :success
    assert_select "#financekit-accounts", count: 0
  end
end
