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

  test "renaming the connection keeps its cached accounts" do
    Rails.cache.write(@key, [ { id: 7, name: "Cached account" } ])

    patch lunchflow_item_url(@item), params: { lunchflow_item: { name: "Renamed" } }, as: :turbo_stream

    assert_equal [ { id: 7, name: "Cached account" } ], Rails.cache.read(@key)
  end
end
