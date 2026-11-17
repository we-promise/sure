require "test_helper"

# Lunch Flow chooses a connection, preloads, offers and links accounts as the
# provider kit does.
class LunchflowItemsSelectionTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = lunchflow_items(:one)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "with two connections, preloading asks which connection to use" do
    second_connection

    get preload_accounts_lunchflow_items_url, as: :json

    assert_equal({ "success" => false, "error" => "select_connection",
                   "error_message" => I18n.t("lunchflow_items.select_accounts.select_connection"), "has_accounts" => nil },
                 response.parsed_body)
  end

  test "with two connections, selecting accounts sends the user to choose one" do
    second_connection

    get select_accounts_lunchflow_items_url(accountable_type: "Depository")

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("lunchflow_items.select_accounts.select_connection"), flash[:alert]
  end

  test "the chosen connection's accounts are offered, and the form names that connection" do
    second = second_connection
    provider_for(@item).expects(:get_accounts).never
    provider_for(second).stubs(:get_accounts).returns(accounts: [ { id: "acc_2", name: "Second savings" } ])

    get select_accounts_lunchflow_items_url(accountable_type: "Depository", lunchflow_item_id: second.id)

    assert_response :success
    assert_includes response.body, "Second savings"
    assert_equal second.id, Nokogiri::HTML(response.body).at_css("input[name='lunchflow_item_id']")["value"]
  end

  test "the existing-account form names the connection" do
    provider_for(@item).stubs(:get_accounts).returns(accounts: [ { id: "acc_1", name: "Checking" } ])

    get select_existing_account_lunchflow_items_url(account_id: accounts(:depository).id)

    assert_response :success
    assert_equal @item.id, Nokogiri::HTML(response.body).at_css("input[name='lunchflow_item_id']")["value"]
  end

  test "an account type Lunch Flow does not support offers nothing" do
    provider_for(@item).stubs(:get_accounts).returns(accounts: [ { id: "acc_1", name: "Checking" } ])

    get select_accounts_lunchflow_items_url(accountable_type: "OtherAsset")

    assert_redirected_to new_account_path
    assert_equal I18n.t("lunchflow_items.select_accounts.no_accounts_found"), flash[:alert]
  end

  test "an unknown existing account redirects instead of a 404" do
    get select_existing_account_lunchflow_items_url(account_id: SecureRandom.uuid)

    assert_redirected_to accounts_path
    assert_equal I18n.t("lunchflow_items.select_existing_account.no_account_specified"), flash[:alert]
  end

  test "an empty account list for an existing account says every account is linked" do
    provider_for(@item).stubs(:get_accounts).returns(accounts: [])

    get select_existing_account_lunchflow_items_url(account_id: accounts(:depository).id)

    assert_redirected_to accounts_path
    assert_equal I18n.t("lunchflow_items.select_existing_account.all_accounts_already_linked"), flash[:alert]
  end

  test "without credentials, selecting accounts outside a frame explains in English" do
    @item.update_column(:api_key, nil)

    get select_accounts_lunchflow_items_url(accountable_type: "Depository")

    assert_redirected_to settings_providers_path
    assert_equal "Please configure your Lunch Flow API key first in Provider Settings.", flash[:alert]
  end

  test "an unexpected preload error reports a translated message, not the raw one" do
    LunchflowItem.any_instance.stubs(:lunchflow_provider).raises(StandardError, "raw internal detail")

    get preload_accounts_lunchflow_items_url, as: :json

    assert_equal "unexpected_error", response.parsed_body["error"]
    assert_equal I18n.t("lunchflow_items.errors.unexpected_error"), response.parsed_body["error_message"]
  end

  test "a cached empty account list is served from the cache" do
    Rails.cache.write("lunchflow_accounts_#{@family.id}_#{@item.id}", [])
    Provider::Lunchflow.any_instance.expects(:get_accounts).never

    get preload_accounts_lunchflow_items_url, as: :json

    assert_equal({ "success" => true, "has_accounts" => false, "cached" => true }, response.parsed_body)
  end

  test "the new-account page offers one Lunch Flow entry per connection when there are several" do
    second = second_connection

    configs = Provider::LunchflowAdapter.connection_configs(family: @family)

    assert_equal [ "lunchflow_#{second.id}", "lunchflow_#{@item.id}" ].sort, configs.map { |config| config[:key] }.sort
    assert_includes configs.find { |config| config[:key] == "lunchflow_#{second.id}" }[:new_account_path].call("Depository", nil), "lunchflow_item_id=#{second.id}"
  end

  test "the new-account page keeps a single Lunch Flow entry for one connection" do
    configs = Provider::LunchflowAdapter.connection_configs(family: @family)

    assert_equal [ [ "lunchflow", "Lunch Flow" ] ], configs.map { |config| config.values_at(:key, :name) }
  end

  test "linking uses the chosen connection's key and links under that connection" do
    second = second_connection
    provider_for(@item).expects(:get_accounts).never
    provider_for(second).stubs(:get_accounts).returns(accounts: [ { id: "acc_2", name: "Second savings", currency: "EUR" } ])

    assert_difference -> { second.lunchflow_accounts.count } => 1, -> { @item.lunchflow_accounts.count } => 0 do
      post link_accounts_lunchflow_items_url, params: { lunchflow_item_id: second.id, account_ids: [ "acc_2" ], accountable_type: "Depository" }
    end

    assert_redirected_to accounts_path
    assert second.lunchflow_accounts.find_by!(account_id: "acc_2").account_provider.present?
  end

  test "linking without any connection redirects instead of creating one" do
    @family.lunchflow_items.destroy_all

    assert_no_difference "LunchflowItem.count" do
      post link_accounts_lunchflow_items_url, params: { account_ids: [ "acc_1" ], accountable_type: "Depository" }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("lunchflow_items.link_accounts.select_connection"), flash[:alert]
  end

  test "linking an account type Lunch Flow does not support is refused" do
    assert_no_difference "Account.count" do
      post link_accounts_lunchflow_items_url, params: { account_ids: [ "acc_1" ], accountable_type: "OtherAsset" }
    end

    assert_redirected_to new_account_path
    assert_equal I18n.t("lunchflow_items.link_accounts.invalid_account_type"), flash[:alert]
  end

  test "linking when the provider lists no accounts fails cleanly" do
    provider_for(@item).stubs(:get_accounts).returns({})

    post link_accounts_lunchflow_items_url, params: { account_ids: [ "acc_1" ], accountable_type: "Depository" }

    assert_redirected_to new_account_path
    assert_equal I18n.t("lunchflow_items.link_accounts.link_failed"), flash[:alert]
  end

  test "linking keeps the currency already stored for a provider account the payload gives none for" do
    @item.lunchflow_accounts.create!(account_id: "acc_eur", name: "Euro account", currency: "EUR")
    provider_for(@item).stubs(:get_accounts).returns(accounts: [ { id: "acc_eur", name: "Euro account" } ])

    post link_accounts_lunchflow_items_url, params: { account_ids: [ "acc_eur" ], accountable_type: "Depository" }

    assert_equal "EUR", @item.lunchflow_accounts.find_by!(account_id: "acc_eur").account.currency
  end

  test "linking reads the connection's cached account list" do
    Rails.cache.write("lunchflow_accounts_#{@family.id}_#{@item.id}", [ { id: "acc_cached", name: "Cached" } ])
    provider_for(@item).expects(:get_accounts).never

    assert_difference "AccountProvider.count", 1 do
      post link_accounts_lunchflow_items_url, params: { account_ids: [ "acc_cached" ], accountable_type: "Depository" }
    end
  end

  test "linking an unknown existing account redirects instead of a 404" do
    post link_existing_account_lunchflow_items_url, params: { account_id: SecureRandom.uuid, lunchflow_account_id: "acc_1" }

    assert_redirected_to accounts_path
    assert_equal "No account specified", flash[:alert]
  end

  test "linking an existing account to a provider account the list lacks says it was not found" do
    provider_for(@item).stubs(:get_accounts).returns(accounts: [ { id: "acc_1", name: "Checking" } ])

    post link_existing_account_lunchflow_items_url, params: { account_id: accounts(:depository).id, lunchflow_account_id: "acc_missing" }

    assert_redirected_to accounts_path
    assert_equal "Lunch Flow account not found", flash[:alert]
  end

  private
    # Its id sorts after the fixture's, so code that silently takes the
    # family's first connection picks the other one.
    def second_connection
      LunchflowItem.create!(id: "ffffffff-ffff-4fff-bfff-ffffffffffff", family: @family, name: "Second Lunch Flow", api_key: "second_key")
    end

    def provider_for(item)
      @providers ||= {}
      @providers[item.id] ||= begin
        provider = mock("lunchflow provider for #{item.name}")
        Provider::Lunchflow.stubs(:new).with(item.api_key, base_url: item.effective_base_url).returns(provider)
        provider
      end
    end
end
