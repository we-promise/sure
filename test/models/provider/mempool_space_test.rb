# frozen_string_literal: true

require "test_helper"

class Provider::MempoolSpaceTest < ActiveSupport::TestCase
  ADDRESS = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"

  setup do
    @provider = Provider::MempoolSpace.new(max_pages: 2)
  end

  test "wallet history lists each transaction once, mempool first" do
    pending = tx("a", confirmed: false)
    stub_json("/address/#{ADDRESS}/txs/mempool", [ pending ])
    stub_json("/address/#{ADDRESS}/txs/chain", [ tx("a"), tx("b") ])

    result = @provider.get_wallet_transactions(ADDRESS)

    assert_equal %w[a b], result.map { |row| row["txid"] }
    assert_equal false, result.first.dig("status", "confirmed")
    refute @provider.truncated
  end

  test "wallet history stops paging at the baseline" do
    stub_json("/address/#{ADDRESS}/txs/mempool", [])
    stub_json("/address/#{ADDRESS}/txs/chain", full_page(time: 2.days.ago))

    @provider.get_wallet_transactions(ADDRESS, since: 1.day.ago)

    assert_not_requested :get, %r{/txs/chain/}
    refute @provider.truncated
  end

  test "wallet history past the page budget is reported as truncated" do
    stub_json("/address/#{ADDRESS}/txs/mempool", [])
    stub_json("/address/#{ADDRESS}/txs/chain", full_page(time: Time.current))
    stub_request(:get, %r{/address/#{ADDRESS}/txs/chain/}).to_return(json(full_page(time: Time.current, prefix: "n")))

    @provider.get_wallet_transactions(ADDRESS, since: 1.day.ago)

    assert_requested :get, %r{/txs/chain/}, times: 1
    assert @provider.truncated
  end

  private
    def tx(id, confirmed: true, time: Time.current)
      { "txid" => id, "vin" => [], "vout" => [],
        "status" => { "confirmed" => confirmed, "block_time" => (time.to_i if confirmed) } }
    end

    def full_page(time:, prefix: "t")
      Array.new(Provider::MempoolSpace::PAGE_SIZE) { |i| tx("#{prefix}#{i}", time: time) }
    end

    def stub_json(path, body)
      stub_request(:get, "#{Provider::MempoolSpace.base_url}#{path}").to_return(json(body))
    end

    def json(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
