# frozen_string_literal: true

require "test_helper"

class Onchain::BitcoinAdapterTest < ActiveSupport::TestCase
  P2PKH = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  P2SH = "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"
  BECH32 = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
  TAPROOT = "bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::BITCOIN)
  end

  test "accepts every address format Bitcoin wallets produce" do
    [ P2PKH, P2SH, BECH32, TAPROOT ].each do |address|
      assert @adapter.valid_address?(address), "#{address} should be accepted"
    end
  end

  test "rejects malformed addresses without making a network call" do
    # WebMock raises on any unstubbed request, so a network call here fails the test.
    [
      "",
      "not-an-address",
      "1A1zP1eP5QGefi2DMPTfTL5SLmv7Divf0a",         # Base58 excludes 0
      "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdb", # bech32 excludes b
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", # an EVM address
      "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz"
    ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "bech32 is canonically lowercase while Base58 keeps its case" do
    # An uppercase bech32 address is valid, but the API reports outputs in lower
    # case: left as typed it yields a correct balance and silently zero movements.
    assert_equal BECH32, @adapter.canonical_address(BECH32.upcase)
    assert_equal TAPROOT, @adapter.canonical_address(" #{TAPROOT.upcase} ")
    # Base58 is case-sensitive; folding it would change the address.
    assert_equal P2PKH, @adapter.canonical_address(P2PKH)
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot("not-an-address")
    end
  end

  test "balance is funded minus spent, including the mempool" do
    stub_address(
      chain_stats: { "funded_txo_sum" => 150_000_000, "spent_txo_sum" => 50_000_000 },
      mempool_stats: { "funded_txo_sum" => 0, "spent_txo_sum" => 25_000_000 }
    )
    stub_transactions([])

    snapshot = @adapter.fetch_snapshot(BECH32)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "BTC", asset.symbol
    assert_equal 8, asset.decimals
    assert_equal BigDecimal("0.75"), asset.quantity
    assert_nil asset.contract
  end

  test "movements are the net effect of each transaction on the address" do
    stub_address
    stub_transactions([
      {
        "txid" => "received",
        "vin" => [ { "prevout" => { "scriptpubkey_address" => "other", "value" => 100_000_000 } } ],
        "vout" => [ { "scriptpubkey_address" => BECH32, "value" => 20_000_000 } ],
        "status" => { "confirmed" => true, "block_time" => Time.utc(2026, 1, 2).to_i }
      },
      {
        "txid" => "spent",
        "vin" => [ { "prevout" => { "scriptpubkey_address" => BECH32, "value" => 20_000_000 } } ],
        "vout" => [
          { "scriptpubkey_address" => "other", "value" => 15_000_000 },
          { "scriptpubkey_address" => BECH32, "value" => 4_000_000 }
        ],
        "status" => { "confirmed" => true, "block_time" => Time.utc(2026, 1, 3).to_i }
      }
    ])

    movements = @adapter.fetch_snapshot(BECH32).movements

    assert_equal [ "received", "spent" ], movements.map(&:external_id)
    assert_equal BigDecimal("0.2"), movements.first.amount
    assert_equal BigDecimal("-0.16"), movements.last.amount
    assert_equal Date.new(2026, 1, 2), movements.first.date
    assert_nil movements.first.contract
  end

  test "self-transfers and unrelated transactions produce no movement" do
    stub_address
    stub_transactions([
      {
        "txid" => "self",
        "vin" => [ { "prevout" => { "scriptpubkey_address" => BECH32, "value" => 10_000_000 } } ],
        "vout" => [ { "scriptpubkey_address" => BECH32, "value" => 10_000_000 } ],
        "status" => { "confirmed" => true, "block_time" => Time.utc(2026, 1, 2).to_i }
      },
      {
        "txid" => "unrelated",
        "vin" => [ { "prevout" => { "scriptpubkey_address" => "other", "value" => 10_000_000 } } ],
        "vout" => [ { "scriptpubkey_address" => "another", "value" => 9_000_000 } ],
        "status" => { "confirmed" => true, "block_time" => Time.utc(2026, 1, 2).to_i }
      }
    ])

    assert_empty @adapter.fetch_snapshot(BECH32).movements
  end

  test "a history longer than the budget is reported as truncated" do
    stub_address
    full_page = Array.new(Provider::MempoolSpace::PAGE_SIZE) do |i|
      {
        "txid" => "tx#{i}",
        "vin" => [],
        "vout" => [ { "scriptpubkey_address" => BECH32, "value" => 1_000 } ],
        "status" => { "confirmed" => true, "block_time" => Time.utc(2026, 1, 2).to_i }
      }
    end
    stub_transactions(full_page)
    stub_request(:get, %r{/address/#{BECH32}/txs/chain/}).to_return(
      status: 200, body: full_page.to_json, headers: { "Content-Type" => "application/json" }
    )

    with_history_budget(2) do
      snapshot = @adapter.fetch_snapshot(BECH32)

      assert snapshot.history_truncated?
      # Balances come from the summary, so they are unaffected by the cap.
      assert_equal 0, snapshot.assets.sole.quantity
    end
  end

  test "an explorer that refuses history still yields the balance" do
    stub_address(chain_stats: { "funded_txo_sum" => 100_000_000, "spent_txo_sum" => 0 })
    stub_request(:get, "#{base_url}/address/#{BECH32}/txs").to_return(status: 429)

    snapshot = @adapter.fetch_snapshot(BECH32)

    assert_equal BigDecimal("1"), snapshot.assets.sole.quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
  end

  test "a timed-out explorer is reported as unreachable, not as an unexpected failure" do
    stub_request(:get, "#{base_url}/address/#{BECH32}").to_timeout

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(BECH32)
    end
  end

  test "a history that fits is not reported as truncated" do
    stub_address
    stub_transactions([])

    assert_not @adapter.fetch_snapshot(BECH32).history_truncated?
  end

  test "an unconfirmed transaction is dated today" do
    stub_address
    stub_transactions([
      {
        "txid" => "pending",
        "vin" => [],
        "vout" => [ { "scriptpubkey_address" => BECH32, "value" => 1_000_000 } ],
        "status" => { "confirmed" => false }
      }
    ])

    assert_equal Date.current, @adapter.fetch_snapshot(BECH32).movements.sole.date
  end

  private
    def with_history_budget(pages)
      previous = ENV["ONCHAIN_HISTORY_MAX_PAGES"]
      ENV["ONCHAIN_HISTORY_MAX_PAGES"] = pages.to_s
      yield
    ensure
      ENV["ONCHAIN_HISTORY_MAX_PAGES"] = previous
    end

    def base_url
      Provider::MempoolSpace.base_url
    end

    def stub_address(chain_stats: { "funded_txo_sum" => 0, "spent_txo_sum" => 0 }, mempool_stats: { "funded_txo_sum" => 0, "spent_txo_sum" => 0 })
      stub_request(:get, "#{base_url}/address/#{BECH32}")
        .to_return(
          status: 200,
          body: { "chain_stats" => chain_stats, "mempool_stats" => mempool_stats }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    def stub_transactions(transactions)
      stub_request(:get, "#{base_url}/address/#{BECH32}/txs")
        .to_return(status: 200, body: transactions.to_json, headers: { "Content-Type" => "application/json" })
    end
end
