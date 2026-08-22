# frozen_string_literal: true

require "test_helper"

class Onchain::EvmAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
  USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM)
  end

  test "accepts a 0x address and rejects anything else without a network call" do
    assert @adapter.valid_address?(ADDRESS)
    assert @adapter.valid_address?(ADDRESS.downcase)

    [ "", "0x123", "0xZZZa6BF26964aF9D7eEd9e03E53415D37aA96045", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq" ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "a checksummed address and its lowercase form are one address" do
    assert_equal ADDRESS.downcase, @adapter.canonical_address(ADDRESS)
    assert_equal ADDRESS.downcase, @adapter.canonical_address(" #{ADDRESS.upcase.sub("0X", "0x")} ")
  end

  test "the same address is valid on every EVM network, which is why detection exists" do
    evm_chains = Onchain::Chains.matching(ADDRESS).map(&:key)

    assert_includes evm_chains, Onchain::Chains::ETHEREUM
    assert_operator evm_chains.size, :>, 1
    assert_not_includes evm_chains, Onchain::Chains::BITCOIN
  end

  test "detection costs exactly one request per network" do
    summary = stub_summary(coin_balance: "5000000000000000000")

    assert @adapter.has_activity?(ADDRESS)
    assert_requested summary, times: 1
  end

  test "a wallet holding only tokens with no native balance is still detected" do
    stub_summary(coin_balance: "0", flags: { "has_tokens" => true })

    assert @adapter.has_activity?(ADDRESS)
  end

  test "an empty address is not detected" do
    stub_summary(coin_balance: "0")

    assert_not @adapter.has_activity?(ADDRESS)
  end

  test "a failing explorer does not break the linking flow" do
    stub_request(:get, summary_url).to_return(status: 500)

    assert_not @adapter.has_activity?(ADDRESS)
  end

  test "two transfers of the same token in one transaction stay two movements" do
    stub_summary(coin_balance: "0")
    stub_token_balances([])
    stub_transactions([])
    # A swap router routinely emits several transfers of one token to the same
    # address within a transaction; the hash and contract alone do not tell them
    # apart, so one of them used to overwrite the other.
    stub_token_transfers([
      token_transfer(hash: "0xswap", log_index: 12, value: "1000000"),
      token_transfer(hash: "0xswap", log_index: 27, value: "3000000")
    ])

    movements = @adapter.fetch_snapshot(ADDRESS).movements

    assert_equal 2, movements.size
    assert_equal 2, movements.map(&:external_id).uniq.size
    assert_equal [ BigDecimal("1"), BigDecimal("3") ], movements.map(&:amount)
  end

  test "an explorer that refuses history still yields the balances" do
    stub_summary(coin_balance: "1500000000000000000")
    stub_token_balances([ erc20(contract: USDC, symbol: "USDC", value: "2500000") ])
    stub_request(:get, "#{explorer_url}/api/v2/addresses/#{ADDRESS}/transactions").to_return(status: 429)
    stub_token_transfers([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal BigDecimal("1.5"), snapshot.find_asset(kind: "native").quantity
    assert_equal BigDecimal("2.5"), snapshot.find_asset(kind: "erc20", contract: USDC).quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
  end

  test "a timed-out explorer is reported as unreachable, not as an unexpected failure" do
    stub_request(:get, %r{#{explorer_url}}).to_timeout

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "detection asks once and does not retry a rate-limited explorer" do
    probe = stub_request(:get, summary_url).to_return(status: 429, body: "rate limited")

    assert_not @adapter.has_activity?(ADDRESS)
    # A 0x address is a candidate on every EVM network and they are asked in
    # turn on the request thread, so retrying with backoff per network is what
    # turns detection into a page that hangs.
    assert_requested probe, times: 1
  end

  test "a timed-out explorer during detection means not detected here" do
    stub_request(:get, summary_url).to_timeout

    assert_not @adapter.has_activity?(ADDRESS)
  end

  test "a malformed address is not probed at all" do
    assert_not @adapter.has_activity?("0x123")
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot("0x123")
    end
  end

  test "reads the native coin and ERC-20 balances, scaled by their decimals" do
    stub_summary(coin_balance: "1500000000000000000")
    stub_token_balances([
      erc20(contract: USDC, symbol: "USDC", name: "USD Coin", value: "2500000"),
      erc20(contract: "0xdust", symbol: "DUST", value: "0", decimals: "18")
    ])
    stub_transactions([])
    stub_token_transfers([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    native = snapshot.find_asset(kind: "native")
    assert_equal "ETH", native.symbol
    assert_equal BigDecimal("1.5"), native.quantity

    token_asset = snapshot.find_asset(kind: "erc20", contract: USDC)
    assert_equal "USDC", token_asset.symbol
    assert_equal 6, token_asset.decimals
    assert_equal BigDecimal("2.5"), token_asset.quantity

    # Zero-balance tokens are dropped: real wallets are full of spam dust.
    assert_equal 2, snapshot.assets.size
  end

  test "token balances are asked for without a type filter, which the API rejects" do
    stub_summary(coin_balance: "0")
    request = stub_token_balances([])
    stub_transactions([])
    stub_token_transfers([])

    @adapter.fetch_snapshot(ADDRESS)

    # Passing ?type=ERC-20 here is a 422: the filter exists on token-transfers,
    # not on token-balances.
    assert_requested request, times: 1
    assert_requested :get, "#{explorer_url}/api/v2/addresses/#{ADDRESS}/token-balances", query: {}
  end

  test "only ERC-20 rows become assets, so an NFT is not read as one token" do
    stub_summary(coin_balance: "0")
    stub_token_balances([
      erc20(contract: USDC, symbol: "USDC", value: "1000000"),
      { "token" => { "address_hash" => "0xnft", "symbol" => "PUNK", "name" => "Punk", "decimals" => nil, "type" => "ERC-721" }, "value" => "1", "token_id" => "42" },
      { "token" => { "address_hash" => "0xmulti", "symbol" => "MULTI", "name" => "Multi", "decimals" => nil, "type" => "ERC-1155" }, "value" => "3" }
    ])
    stub_transactions([])
    stub_token_transfers([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal [ USDC ], snapshot.assets.filter_map(&:contract_key)
    assert_nil snapshot.find_asset(kind: "erc20", contract: "0xnft")
  end

  test "only a priced holding above dust is pre-ticked, whatever its symbol" do
    stub_summary(coin_balance: "1000000000000000000")
    stub_token_balances([
      erc20(contract: USDC, symbol: "USDC", value: "2500000", market_cap: "40000000000", rate: "1"),
      # A plausible symbol, a real market cap, and 0.000001 of it: an airdrop.
      erc20(contract: "0xdust", symbol: "0XBTC", value: "1", market_cap: "5000000", rate: "0.5"),
      # Priced by nothing at all.
      erc20(contract: "0xunpriced", symbol: "MEH", value: "5000000")
    ])
    stub_transactions([])
    stub_token_transfers([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert snapshot.find_asset(kind: "native").notable?
    assert snapshot.find_asset(kind: "erc20", contract: USDC).notable?
    assert_not snapshot.find_asset(kind: "erc20", contract: "0xdust").notable?
    assert_not snapshot.find_asset(kind: "erc20", contract: "0xunpriced").notable?
  end

  test "an airdrop dump is capped, keeping the tokens with a market cap" do
    stub_summary(coin_balance: "0")
    stub_token_balances([
      erc20(contract: "0xspam1", symbol: "SPAM1", value: "1000000"),
      erc20(contract: USDC, symbol: "USDC", value: "1000000", market_cap: "40000000000"),
      erc20(contract: "0xspam2", symbol: "SPAM2", value: "1000000"),
      erc20(contract: "0xmid", symbol: "MID", value: "1000000", market_cap: "1000000")
    ])
    stub_transactions([])
    stub_token_transfers([])

    with_asset_budget(2) do
      snapshot = @adapter.fetch_snapshot(ADDRESS)

      assert snapshot.assets_truncated?
      # Ranked by market cap, so the credible assets survive the cap and the
      # native coin is never at risk.
      assert_equal [ nil, USDC, "0xmid" ], snapshot.assets.map(&:contract_key)
    end
  end

  test "the cap keeps the same tokens between two reads of an unchanged address" do
    stub_summary(coin_balance: "0")
    stub_token_balances([
      erc20(contract: "0xbbb", symbol: "B", value: "1000000"),
      erc20(contract: "0xaaa", symbol: "A", value: "1000000"),
      erc20(contract: "0xccc", symbol: "C", value: "1000000")
    ])
    stub_transactions([])
    stub_token_transfers([])

    with_asset_budget(2) do
      first = @adapter.fetch_snapshot(ADDRESS).assets.map(&:contract_key)
      second = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM).fetch_snapshot(ADDRESS).assets.map(&:contract_key)

      assert_equal first, second
    end
  end

  test "an address within the budget is not reported as capped" do
    stub_summary(coin_balance: "0")
    stub_token_balances([ erc20(contract: USDC, symbol: "USDC", value: "1000000") ])
    stub_transactions([])
    stub_token_transfers([])

    assert_not @adapter.fetch_snapshot(ADDRESS).assets_truncated?
  end

  test "the native asset is reported even when the wallet is empty" do
    stub_summary(coin_balance: "0")
    stub_token_balances([])
    stub_transactions([])
    stub_token_transfers([])

    assert_equal 0, @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "native").quantity
  end

  test "movements are signed by direction and carry the token contract" do
    stub_summary(coin_balance: "0")
    stub_token_balances([])
    stub_transactions([
      { "hash" => "0xin", "from" => { "hash" => "0xother" }, "to" => { "hash" => ADDRESS.downcase }, "value" => "2000000000000000000", "timestamp" => "2026-01-02T00:00:00.000000Z" },
      { "hash" => "0xout", "from" => { "hash" => ADDRESS.downcase }, "to" => { "hash" => "0xother" }, "value" => "1000000000000000000", "timestamp" => "2026-01-03T00:00:00.000000Z" },
      { "hash" => "0xself", "from" => { "hash" => ADDRESS.downcase }, "to" => { "hash" => ADDRESS.downcase }, "value" => "5", "timestamp" => "2026-01-04T00:00:00.000000Z" }
    ])
    stub_token_transfers([
      {
        "transaction_hash" => "0xtoken",
        "from" => { "hash" => "0xother" },
        "to" => { "hash" => ADDRESS.downcase },
        "timestamp" => "2026-01-05T00:00:00.000000Z",
        "token" => { "address_hash" => USDC, "symbol" => "USDC", "decimals" => "6" },
        "total" => { "value" => "1500000", "decimals" => "6" }
      }
    ])

    movements = @adapter.fetch_snapshot(ADDRESS).movements

    assert_equal [ "0xin", "0xout", "0xtoken_#{USDC}" ], movements.map(&:external_id)
    assert_equal BigDecimal("2"), movements[0].amount
    assert_equal BigDecimal("-1"), movements[1].amount
    assert_nil movements[0].contract
    assert_equal BigDecimal("1.5"), movements[2].amount
    assert_equal USDC, movements[2].contract_key
    assert_equal Date.new(2026, 1, 5), movements[2].date
  end

  test "a key moves history onto Etherscan but never balances" do
    assert_instance_of Provider::Blockscout, @adapter.balance_backend
    assert_instance_of Provider::Blockscout, @adapter.history_backend

    keyed = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM, credentials: { etherscan_api_key: "key" })

    assert_instance_of Provider::Blockscout, keyed.balance_backend
    assert_instance_of Provider::Etherscan, keyed.history_backend
  end

  test "an Etherscan key is ignored on networks the registry does not enable it for" do
    polygon = Onchain::Chains.adapter_for("polygon", credentials: { etherscan_api_key: "key" })

    assert_instance_of Provider::Blockscout, polygon.history_backend
  end

  test "with a key configured, balances still come from the indexer and history from Etherscan" do
    keyed = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM, credentials: { etherscan_api_key: "key" })
    stub_summary(coin_balance: "3000000000000000000")
    stub_token_balances([ erc20(contract: USDC, symbol: "USDC", name: "USD Coin", value: "7000000") ])
    etherscan_history = stub_etherscan_history

    snapshot = keyed.fetch_snapshot(ADDRESS)

    # Summing Etherscan's transfers would report 1 USDC, not the 7 actually held:
    # the indexer is the only backend that can answer this.
    assert_equal BigDecimal("7"), snapshot.find_asset(kind: "erc20", contract: USDC).quantity
    assert_equal BigDecimal("3"), snapshot.find_asset(kind: "native").quantity
    assert_equal [ "0xkeyed", "0xkeyedtoken_#{USDC}" ], snapshot.movements.map(&:external_id)
    assert_requested etherscan_history, times: 2
  end

  test "Etherscan refuses to answer token balances rather than approximating them" do
    keyed = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM, credentials: { etherscan_api_key: "key" })

    assert_raises NotImplementedError do
      keyed.history_backend.token_balances(ADDRESS)
    end
  end

  test "each network reads its own explorer" do
    ethereum = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM)
    base = Onchain::Chains.adapter_for("base")

    assert_not_equal ethereum.explorer_url, base.explorer_url
  end

  private
    def with_asset_budget(tokens)
      previous = ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"]
      ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"] = tokens.to_s
      yield
    ensure
      ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"] = previous
    end

    def summary_url
      "#{explorer_url}/api/v2/addresses/#{ADDRESS}"
    end

    def explorer_url
      @adapter.explorer_url
    end

    def stub_summary(coin_balance:, flags: {})
      stub_request(:get, summary_url).to_return(
        status: 200,
        body: { "coin_balance" => coin_balance }.merge(flags).to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    # Blockscout returns this collection as a bare array rather than a paginated
    # envelope, unlike the transfer endpoints below, and it rejects a `type`
    # filter outright — hence the bare path.
    def stub_token_balances(items)
      stub_request(:get, "#{explorer_url}/api/v2/addresses/#{ADDRESS}/token-balances")
        .to_return(status: 200, body: items.to_json, headers: { "Content-Type" => "application/json" })
    end

    def erc20(contract:, symbol:, value:, decimals: "6", name: nil, market_cap: nil, rate: nil)
      {
        "token" => {
          "address_hash" => contract, "symbol" => symbol, "name" => name || symbol,
          "decimals" => decimals, "type" => "ERC-20",
          "circulating_market_cap" => market_cap, "exchange_rate" => rate
        },
        "value" => value
      }
    end

    def stub_transactions(items)
      stub_items("#{explorer_url}/api/v2/addresses/#{ADDRESS}/transactions", items)
    end

    def stub_token_transfers(items)
      stub_items("#{explorer_url}/api/v2/addresses/#{ADDRESS}/token-transfers?type=ERC-20", items)
    end

    # One stub for both Etherscan actions; the query string differs only by action.
    def stub_etherscan_history
      stub_request(:get, "#{Provider::Etherscan::BASE_URL}/api")
        .with(query: hash_including({ "module" => "account" }))
        .to_return do |request|
          action = CGI.parse(URI(request.uri).query)["action"].first
          result = case action
          when "txlist"
            [ { "hash" => "0xkeyed", "from" => "0xother", "to" => ADDRESS.downcase, "value" => "1000000000000000000", "timeStamp" => Time.utc(2026, 1, 2).to_i.to_s } ]
          when "tokentx"
            [ {
              "hash" => "0xkeyedtoken", "from" => "0xother", "to" => ADDRESS.downcase,
              "contractAddress" => USDC, "tokenSymbol" => "USDC", "tokenDecimal" => "6",
              "value" => "1000000", "timeStamp" => Time.utc(2026, 1, 3).to_i.to_s
            } ]
          else
            []
          end

          { status: 200, body: { "status" => "1", "message" => "OK", "result" => result }.to_json, headers: { "Content-Type" => "application/json" } }
        end
    end

    def token_transfer(hash:, log_index:, value:, contract: USDC)
      {
        "transaction_hash" => hash,
        "log_index" => log_index,
        "from" => { "hash" => "0xother" },
        "to" => { "hash" => ADDRESS.downcase },
        "timestamp" => "2026-01-05T00:00:00.000000Z",
        "token" => { "address_hash" => contract, "symbol" => "USDC", "decimals" => "6", "type" => "ERC-20" },
        "total" => { "value" => value, "decimals" => "6" }
      }
    end

    def stub_items(url, items)
      stub_request(:get, url).to_return(
        status: 200,
        body: { "items" => items, "next_page_params" => nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end
end
