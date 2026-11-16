require "test_helper"

# Mercury preloads, offers and links accounts as the provider kit does.
class MercuryItemsSelectionTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = mercury_items(:one)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "preloading with an unknown connection id asks which connection to use" do
    get preload_accounts_mercury_items_url(mercury_item_id: SecureRandom.uuid), as: :json

    assert_equal [ "select_connection", I18n.t("mercury_items.select_accounts.select_connection") ],
                 response.parsed_body.values_at("error", "error_message")
  end

  test "an unexpected preload error reports a translated message, not the raw one" do
    MercuryItem.any_instance.stubs(:mercury_provider).raises(StandardError, "raw internal detail")

    get preload_accounts_mercury_items_url, as: :json

    assert_equal [ "unexpected_error", I18n.t("mercury_items.errors.unexpected_error") ],
                 response.parsed_body.values_at("error", "error_message")
  end

  test "a cached empty account list is served from the cache" do
    Rails.cache.write("mercury_accounts_#{@family.id}_#{@item.id}", [])
    Provider::Mercury.any_instance.expects(:get_accounts).never

    get preload_accounts_mercury_items_url, as: :json

    assert_equal({ "success" => true, "has_accounts" => false, "cached" => true }, response.parsed_body)
  end

  test "an account type Mercury does not support offers nothing" do
    stub_accounts([ { id: "acc_1", name: "Checking" } ])

    get select_accounts_mercury_items_url(accountable_type: "CreditCard")

    assert_redirected_to new_account_path
    assert_equal I18n.t("mercury_items.select_accounts.no_accounts_found"), flash[:alert]
  end

  test "an unknown existing account redirects instead of a 404" do
    get select_existing_account_mercury_items_url(account_id: SecureRandom.uuid)

    assert_redirected_to accounts_path
    assert_equal I18n.t("mercury_items.select_existing_account.no_account_specified"), flash[:alert]
  end

  test "an empty account list for an existing account says every account is linked" do
    stub_accounts([])

    get select_existing_account_mercury_items_url(account_id: accounts(:depository).id)

    assert_redirected_to accounts_path
    assert_equal I18n.t("mercury_items.select_existing_account.all_accounts_already_linked"), flash[:alert]
  end

  test "linking an account type Mercury does not support is refused" do
    assert_no_difference "Account.count" do
      post link_accounts_mercury_items_url, params: { account_ids: [ "acc_1" ], accountable_type: "CreditCard" }
    end

    assert_redirected_to new_account_path
    assert_equal I18n.t("mercury_items.link_accounts.invalid_account_type"), flash[:alert]
  end

  test "linking when the provider lists no accounts fails cleanly" do
    stub_accounts(nil)

    post link_accounts_mercury_items_url, params: { account_ids: [ "acc_1" ], accountable_type: "Depository" }

    assert_redirected_to new_account_path
    assert_equal I18n.t("mercury_items.link_accounts.link_failed"), flash[:alert]
  end

  test "linking reads the connection's cached account list" do
    Rails.cache.write("mercury_accounts_#{@family.id}_#{@item.id}", [ { id: "acc_cached", name: "Cached" } ])
    Provider::Mercury.any_instance.expects(:get_accounts).never

    assert_difference "AccountProvider.count", 1 do
      post link_accounts_mercury_items_url, params: { account_ids: [ "acc_cached" ], accountable_type: "Depository" }
    end
  end

  test "linking an unknown existing account redirects instead of a 404" do
    post link_existing_account_mercury_items_url, params: { account_id: SecureRandom.uuid, mercury_account_id: "acc_1" }

    assert_redirected_to accounts_path
    assert_equal "No account specified", flash[:alert]
  end

  test "linking an existing account to a provider account the list lacks says it was not found" do
    stub_accounts([ { id: "acc_1", name: "Checking" } ])

    post link_existing_account_mercury_items_url, params: { account_id: accounts(:depository).id, mercury_account_id: "acc_missing" }

    assert_redirected_to accounts_path
    assert_equal "Mercury account not found", flash[:alert]
  end

  test "a connection whose token is blank doesn't count as a second connection" do
    MercuryItem.create!(family: @family, name: "Blanked", token: "temporary").update_column(:token, " ")
    stub_accounts([ { id: "acc_1", name: "Checking" } ])

    get select_accounts_mercury_items_url(accountable_type: "Depository")

    assert_response :success
    assert_includes response.body, "Checking"
  end

  private
    def stub_accounts(accounts)
      Provider::Mercury.any_instance.stubs(:get_accounts).returns(accounts: accounts)
    end
end
