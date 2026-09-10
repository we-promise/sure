require "test_helper"

class Provider::Trading212Test < ActiveSupport::TestCase
  test "pagination follows next page path with all query parameters" do
    provider = Provider::Trading212.new(api_key: "key", api_secret: "secret")
    next_page_path = "/equity/history/transactions?limit=50&cursor=cursor-2&time=2026-09-10T12%3A00%3A00Z"

    provider.expects(:get).with("/equity/history/transactions", query: { limit: 50 }).returns({
      "items" => [ { "id" => "transaction-1" } ],
      "nextPagePath" => next_page_path
    })
    provider.expects(:get).with(next_page_path).returns({
      "items" => [ { "id" => "transaction-2" } ],
      "nextPagePath" => nil
    })
    provider.stubs(:sleep)

    assert_equal [
      { "id" => "transaction-1" },
      { "id" => "transaction-2" }
    ], provider.fetch_all_transactions
  end
end
