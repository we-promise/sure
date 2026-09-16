require "test_helper"

class Provider::Trading212PagesTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body, keyword_init: true)

  setup do
    @client = Provider::Trading212.new(api_key: "key", api_secret: "secret")
    @client.stubs(:sleep)
  end

  test "canonical readers decode exact decimal JSON and retain the original response" do
    Provider::Trading212.expects(:get).once.returns(Response.new(code: 200, body: '{"id":1,"totalValue":1.123456789012345678}'))

    result = @client.fetch_account_summary_page

    assert_equal BigDecimal("1.123456789012345678"), result[:items].first["totalValue"]
    assert_equal result[:items].first, result[:evidence]
    assert_nil result[:next_cursor]
  end

  test "a single history page preserves the entire continuation query without fetching another page" do
    path = "/api/v0/equity/history/orders?limit=50&cursor=next&time=2026-09-10T12%3A00%3A00Z"
    Provider::Trading212.expects(:get).once.with { |url, options|
      url == "https://live.trading212.com#{path}" && options[:query] == {} && options[:headers]["Authorization"] == "Basic #{Base64.strict_encode64('key:secret')}"
    }.returns(Response.new(code: 200, body: { items: [ { id: "order" } ], nextPagePath: path.sub("cursor=next", "cursor=last") }.to_json))

    result = @client.fetch_orders_page(cursor: path)

    assert_equal 1, result[:items].size
    assert_includes result[:next_cursor], "cursor=last"
    assert_equal result[:next_cursor], result[:evidence]["nextPagePath"]
  end

  test "foreign host fragment and different resource continuations cannot send credentials" do
    Provider::Trading212.expects(:get).never
    [ "https://attacker.test/equity/history/orders", "//attacker.test/equity/history/orders", "/equity/history/orders#private",
      "/equity/history/dividends?cursor=wrong-resource" ].each do |cursor|
      assert_raises(Provider::Trading212::ApiError) { @client.fetch_orders_page(cursor: cursor) }
    end
  end

  test "malformed and oversized histories never become empty or complete responses" do
    [ {}, { items: nil }, { items: [ nil ] }, { items: Array.new(51) { { id: 1 } } }, { items: [], nextPagePath: false } ].each do |payload|
      Provider::Trading212.expects(:get).once.returns(Response.new(code: 200, body: payload.to_json))
      assert_raises(Provider::Trading212::ApiError) { @client.fetch_orders_page }
    end
  end

  test "canonical API failures strip response bodies and error causes" do
    Provider::Trading212.expects(:get).once.returns(Response.new(code: 500, body: "private-financial-payload"))

    error = assert_raises(Provider::Trading212::ApiError) { @client.fetch_positions_page }

    assert_nil error.response_body
    assert_nil error.cause
    assert_equal 500, error.status_code
    refute_includes error.message, "private-financial-payload"
  end
end
