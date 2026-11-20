require "test_helper"

# The Lunch Flow accounts list is cached per connection, under the provider
# kit's key, and dropped when the connection's credentials change.
class LunchflowItemsAccountCacheTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = lunchflow_items(:one)
    @key = "lunchflow_accounts_#{@item.family_id}_#{@item.id}"
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Provider::Lunchflow.any_instance.stubs(:get_accounts).returns(accounts: [ { id: 1, name: "Everyday" } ])
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "preloading caches the accounts under the connection's key" do
    get preload_accounts_lunchflow_items_url, as: :json

    assert_equal [ { id: 1, name: "Everyday" } ], Rails.cache.read(@key)
    assert_nil Rails.cache.read("lunchflow_accounts_#{@item.family_id}")
  end

  test "selecting accounts reads the connection's cached list" do
    Rails.cache.write(@key, [ { id: 7, name: "Cached account" } ])
    Provider::Lunchflow.any_instance.expects(:get_accounts).never

    get select_accounts_lunchflow_items_url(accountable_type: "Depository")

    assert_includes response.body, "Cached account"
  end

  test "changing the API key drops the connection's cached accounts" do
    Rails.cache.write(@key, [ { id: 7, name: "Cached account" } ])

    patch lunchflow_item_url(@item), params: { lunchflow_item: { api_key: "new_key" } }, as: :turbo_stream

    assert_nil Rails.cache.read(@key)
  end

  test "changing the base URL drops the connection's cached accounts" do
    Rails.cache.write(@key, [ { id: 7, name: "Cached account" } ])

    patch lunchflow_item_url(@item), params: { lunchflow_item: { base_url: "https://lunchflow.example/api" } }, as: :turbo_stream

    assert_nil Rails.cache.read(@key)
  end

  # A fetch that started under the old API key must not write the old key's
  # accounts back after an update dropped the cache mid-fetch. The key changes
  # in another request, so this request's query cache still holds the row as
  # it was read before the fetch.
  [
    [ "preloading", -> { get preload_accounts_lunchflow_items_url, as: :json } ],
    [ "selecting accounts", -> { get select_accounts_lunchflow_items_url(accountable_type: "Depository") } ],
    [ "selecting an existing account's link", -> { get select_existing_account_lunchflow_items_url(account_id: accounts(:depository).id) } ]
  ].each do |action, request|
    test "#{action} does not cache accounts fetched under an API key changed mid-fetch" do
      item = @item
      Provider::Lunchflow.any_instance.unstub(:get_accounts)
      Provider::Lunchflow.any_instance.stubs(:get_accounts).with do
        rotate_api_key_elsewhere(item, "rotated_key")
        true
      end.returns(accounts: [ { id: 1, name: "Old key's account" } ])

      instance_exec(&request)

      assert_nil Rails.cache.read(@key)
    end
  end

  test "renaming the connection keeps its cached accounts" do
    Rails.cache.write(@key, [ { id: 7, name: "Cached account" } ])

    patch lunchflow_item_url(@item), params: { lunchflow_item: { name: "Renamed" } }, as: :turbo_stream

    assert_equal [ { id: 7, name: "Cached account" } ], Rails.cache.read(@key)
  end

  private
    # Reads the row, as earlier code in the request may, then changes the key
    # on the raw connection, which leaves Active Record's query cache holding
    # the old row, as a write from another request would.
    def rotate_api_key_elsewhere(item, api_key)
      LunchflowItem.find_by(id: item.id)
      LunchflowItem.connection.raw_connection.exec_params(
        "UPDATE lunchflow_items SET api_key = $1 WHERE id = $2",
        [ LunchflowItem.type_for_attribute(:api_key).serialize(api_key), item.id ]
      )
    end
end
