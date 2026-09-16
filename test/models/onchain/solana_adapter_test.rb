# frozen_string_literal: true

require "test_helper"

class Onchain::SolanaAdapterTest < ActiveSupport::TestCase
  ADDRESS = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  TOKEN_ACCOUNT = "4Qk1Ai1cWJKQZ4pQ9sTLC1z3TBcvxRuHF6vRzGBNRUR2"
  USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  UNKNOWN_MINT = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::SOLANA)
  end

  test "accepts a Base58 pubkey and rejects anything outside the character set" do
    assert @adapter.valid_address?(ADDRESS)

    [ "", "short", "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "#{ADDRESS[0..-2]}0" ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot("nope")
    end
  end

  test "activity is one request, and a node that rejects the key means not here" do
    balance = stub_rpc("getBalance", { "value" => 2_000_000_000 })

    assert @adapter.has_activity?(ADDRESS)
    assert_requested balance, times: 1
  end

  test "an address the node rejects is not detected instead of raising" do
    stub_request(:post, Provider::SolanaRpc.url)
      .to_return(status: 200, body: { "error" => { "message" => "Invalid param: WrongSize" } }.to_json, headers: json_headers)

    assert_not @adapter.has_activity?(ADDRESS)
  end

  test "a node that refuses history still yields the balances" do
    stub_request(:post, Provider::SolanaRpc.url).to_return do |request|
      method = JSON.parse(request.body)["method"]
      # Balances answer; the history methods are throttled, as the free endpoint
      # does in practice.
      case method
      when "getBalance"
        { status: 200, body: { "result" => { "value" => 2_000_000_000 } }.to_json, headers: json_headers }
      when "getTokenAccountsByOwner"
        accounts = request.body.include?(Provider::SolanaRpc::TOKEN_PROGRAM_IDS.first) ?
          [ token_account(mint: USDC_MINT, amount: "1000000", decimals: 6) ] : []
        { status: 200, body: { "result" => { "value" => accounts } }.to_json, headers: json_headers }
      else
        { status: 429, body: "rate limited" }
      end
    end
    stub_token_list([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal BigDecimal("2"), snapshot.find_asset(kind: "native").quantity
    assert_equal BigDecimal("1"), snapshot.find_asset(kind: "spl", contract: USDC_MINT).quantity
    assert_empty snapshot.movements
    # Reported as incomplete, not as a wallet that never moved.
    assert snapshot.history_truncated?
  end

  test "a timed-out node is reported as unreachable, not as an unexpected failure" do
    stub_request(:post, Provider::SolanaRpc.url).to_timeout

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "SPL balances come from the wallet's token accounts, summed per mint" do
    stub_snapshot(
      lamports: 1_500_000_000,
      token_accounts: [
        token_account(mint: USDC_MINT, amount: "2000000", decimals: 6),
        token_account(mint: USDC_MINT, amount: "500000", decimals: 6, pubkey: "second"),
        token_account(mint: UNKNOWN_MINT, amount: "0", decimals: 9)
      ]
    )

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    native = snapshot.find_asset(kind: "native")
    assert_equal "SOL", native.symbol
    assert_equal BigDecimal("1.5"), native.quantity

    usdc = snapshot.find_asset(kind: "spl", contract: USDC_MINT)
    assert_equal "USDC", usdc.symbol
    assert_equal BigDecimal("2.5"), usdc.quantity

    # An emptied token account is left behind on Solana by design.
    assert_nil snapshot.find_asset(kind: "spl", contract: UNKNOWN_MINT)
  end

  test "a verified mint gets its real symbol from the token list" do
    stub_snapshot(lamports: 0, token_accounts: [ token_account(mint: UNKNOWN_MINT, amount: "1500000", decimals: 6) ])
    stub_token_list([ { "id" => UNKNOWN_MINT, "symbol" => "PYTH", "name" => "Pyth Network", "isVerified" => true } ])

    asset = @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "spl", contract: UNKNOWN_MINT)

    assert_equal "PYTH", asset.symbol
    assert_equal "Pyth Network", asset.name
    assert_equal "CRYPTO:PYTH", Onchain::SecurityResolver.resolve(symbol: asset.symbol).ticker
  end

  test "only a mint the list vouches for is pre-tickable" do
    stub_snapshot(lamports: 0, token_accounts: [
      token_account(mint: USDC_MINT, amount: "1000000", decimals: 6),
      token_account(mint: UNKNOWN_MINT, amount: "1000000", decimals: 6, pubkey: "other")
    ])
    stub_token_list([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert snapshot.find_asset(kind: "spl", contract: USDC_MINT).notable?
    assert_not snapshot.find_asset(kind: "spl", contract: UNKNOWN_MINT).notable?
  end

  test "an unverified mint keeps a label that cannot be mistaken for a ticker" do
    # A token calling itself USDC, which the list does not vouch for. Naming it
    # would hand it the real dollar's price.
    stub_snapshot(lamports: 0, token_accounts: [ token_account(mint: UNKNOWN_MINT, amount: "1000000000", decimals: 9) ])
    stub_token_list([ { "id" => UNKNOWN_MINT, "symbol" => "USDC", "name" => "USD Coin", "isVerified" => false } ])

    asset = @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "spl", contract: UNKNOWN_MINT)

    assert_no_match(/USDC/, asset.symbol)
    assert_nil Onchain::SecurityResolver.resolve(symbol: asset.symbol)
  end

  test "a mint keeps its Base58 case, because case is part of the key" do
    mixed = "So11111111111111111111111111111111111111112"
    stub_snapshot(lamports: 0, token_accounts: [ token_account(mint: mixed, amount: "1000000", decimals: 6) ])
    stub_token_list([])

    asset = @adapter.fetch_snapshot(ADDRESS).assets.find { |a| !a.native? }

    assert_equal mixed, asset.contract
    assert_equal mixed, asset.contract_key
    # A Solana address is not canonicalised either: every character is meaningful.
    assert_equal ADDRESS, @adapter.canonical_address(" #{ADDRESS} ")
  end

  test "an unknown mint is labelled so it cannot be mistaken for a ticker" do
    stub_snapshot(lamports: 0, token_accounts: [ token_account(mint: UNKNOWN_MINT, amount: "1000000000", decimals: 9) ])
    stub_token_list([])

    asset = @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "spl", contract: UNKNOWN_MINT)

    assert_equal UNKNOWN_MINT, asset.contract
    assert_nil Onchain::SecurityResolver.resolve(symbol: asset.symbol)
  end

  test "an airdrop dump is capped, and the cap bounds the metadata lookups too" do
    mints = Array.new(5) { |i| "#{UNKNOWN_MINT[0..-3]}#{i}#{i}" }
    stub_snapshot(
      lamports: 0,
      token_accounts: mints.map { |mint| token_account(mint: mint, amount: "1000000", decimals: 6) }
    )
    list = stub_token_list([])

    with_asset_budget(2) do
      snapshot = @adapter.fetch_snapshot(ADDRESS)

      assert snapshot.assets_truncated?
      # Native plus the two surfaced mints, and one metadata request rather than
      # one per batch of the whole dump.
      assert_equal 3, snapshot.assets.size
      assert_requested list, times: 1
    end
  end

  test "the cap keeps the same mints between two reads of an unchanged address" do
    mints = %w[ccc aaa bbb].map { |suffix| "#{UNKNOWN_MINT[0..-4]}#{suffix}" }
    stub_snapshot(
      lamports: 0,
      token_accounts: mints.map { |mint| token_account(mint: mint, amount: "1000000", decimals: 6) }
    )
    stub_token_list([])

    with_asset_budget(2) do
      first = @adapter.fetch_snapshot(ADDRESS).assets.map(&:contract)
      second = Onchain::Chains.adapter_for(Onchain::Chains::SOLANA).fetch_snapshot(ADDRESS).assets.map(&:contract)

      assert_equal first, second
    end
  end

  test "a token list that is down leaves the wallet readable" do
    stub_snapshot(lamports: 1_000_000_000, token_accounts: [ token_account(mint: UNKNOWN_MINT, amount: "1000000000", decimals: 9) ])
    stub_request(:get, /lite-api\.jup\.ag/).to_return(status: 503)

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal BigDecimal("1"), snapshot.find_asset(kind: "native").quantity
    assert_equal 2, snapshot.assets.size
  end

  test "hard-coded mints resolve without asking the token list" do
    stub_snapshot(lamports: 0, token_accounts: [ token_account(mint: USDC_MINT, amount: "1000000", decimals: 6) ])
    list = stub_token_list([])

    assert_equal "USDC", @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "spl", contract: USDC_MINT).symbol
    assert_not_requested list
  end

  test "movements and assets agree on a token's name" do
    stub_snapshot(
      lamports: 0,
      token_accounts: [ token_account(mint: UNKNOWN_MINT, amount: "1000000", decimals: 6) ],
      signatures: [ { "signature" => "sig1", "blockTime" => Time.utc(2026, 2, 3).to_i } ],
      transaction: {
        "blockTime" => Time.utc(2026, 2, 3).to_i,
        "meta" => {
          "err" => nil, "preBalances" => [ 0 ], "postBalances" => [ 0 ],
          "preTokenBalances" => [],
          "postTokenBalances" => [ { "owner" => ADDRESS, "mint" => UNKNOWN_MINT, "uiTokenAmount" => { "amount" => "1000000", "decimals" => 6 } } ]
        },
        "transaction" => { "message" => { "accountKeys" => [ { "pubkey" => ADDRESS } ] } }
      }
    )
    stub_token_list([ { "id" => UNKNOWN_MINT, "symbol" => "PYTH", "name" => "Pyth Network", "isVerified" => true } ])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal "PYTH", snapshot.movements.sole.symbol
    assert_equal [ "PYTH" ], snapshot.assets.select { |asset| asset.contract == UNKNOWN_MINT }.map(&:symbol)
  end

  test "the snapshot has the same shape as the other chains" do
    stub_snapshot(lamports: 1_000_000_000, token_accounts: [])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_instance_of Onchain::Snapshot, snapshot
    assert snapshot.assets.all? { |asset| asset.is_a?(Onchain::Asset) }
    assert snapshot.movements.all? { |movement| movement.is_a?(Onchain::Movement) }
  end

  test "movements come from pre/post balances, with fee-only changes dropped" do
    stub_snapshot(
      lamports: 1_000_000_000,
      token_accounts: [ token_account(mint: USDC_MINT, amount: "1000000", decimals: 6) ],
      signatures: [ { "signature" => "sig1", "blockTime" => Time.utc(2026, 2, 3).to_i } ],
      transaction: {
        "blockTime" => Time.utc(2026, 2, 3).to_i,
        "meta" => {
          "err" => nil,
          "preBalances" => [ 1_000_000_000 ],
          "postBalances" => [ 2_000_000_000 ],
          "preTokenBalances" => [ { "owner" => ADDRESS, "mint" => USDC_MINT, "uiTokenAmount" => { "amount" => "0", "decimals" => 6 } } ],
          "postTokenBalances" => [ { "owner" => ADDRESS, "mint" => USDC_MINT, "uiTokenAmount" => { "amount" => "1000000", "decimals" => 6 } } ]
        },
        "transaction" => { "message" => { "accountKeys" => [ { "pubkey" => ADDRESS } ] } }
      }
    )

    movements = @adapter.fetch_snapshot(ADDRESS).movements

    native = movements.find { |movement| movement.contract.nil? }
    assert_equal "sig1", native.external_id
    assert_equal BigDecimal("1"), native.amount
    assert_equal Date.new(2026, 2, 3), native.date

    token_asset = movements.find { |movement| movement.contract == USDC_MINT }
    assert_equal "sig1_#{USDC_MINT}", token_asset.external_id
    assert_equal BigDecimal("1"), token_asset.amount
  end

  test "a failed transaction produces no movements" do
    stub_snapshot(
      lamports: 0,
      token_accounts: [],
      signatures: [ { "signature" => "sig1", "blockTime" => Time.utc(2026, 2, 3).to_i } ],
      transaction: {
        "meta" => { "err" => { "InstructionError" => [] }, "preBalances" => [ 0 ], "postBalances" => [ 5_000_000_000 ] },
        "transaction" => { "message" => { "accountKeys" => [ { "pubkey" => ADDRESS } ] } }
      }
    )

    assert_empty @adapter.fetch_snapshot(ADDRESS).movements
  end

  test "a fee-only balance change is not a transfer" do
    stub_snapshot(
      lamports: 0,
      token_accounts: [],
      signatures: [ { "signature" => "sig1", "blockTime" => Time.utc(2026, 2, 3).to_i } ],
      transaction: {
        "meta" => { "err" => nil, "preBalances" => [ 1_000_000_000 ], "postBalances" => [ 999_995_000 ] },
        "transaction" => { "message" => { "accountKeys" => [ { "pubkey" => ADDRESS } ] } }
      }
    )

    assert_empty @adapter.fetch_snapshot(ADDRESS).movements
  end

  test "a full page of signatures is incomplete history, not the whole of it" do
    page = Array.new(Onchain::SolanaAdapter::SIGNATURES_PER_SOURCE) do |index|
      { "signature" => "sig#{index}", "blockTime" => Time.utc(2026, 2, 3).to_i - index }
    end
    stub_snapshot(lamports: 1_000_000_000, token_accounts: [], signatures: page)
    stub_token_list([])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    # The page came back full and the adapter passes no cursor, so older
    # signatures exist that were never asked for. Counting against the budget
    # alone would call this a complete history.
    assert snapshot.history_truncated?
  end

  test "a wallet holding SPL tokens but no SOL is still detected" do
    stub_snapshot(
      lamports: 0,
      token_accounts: [ token_account(mint: USDC_MINT, amount: "1000000", decimals: 6) ]
    )

    # Each token account carries its own rent, so a wallet address emptied of SOL
    # is not an emptied wallet.
    assert @adapter.has_activity?(ADDRESS)
  end

  test "token accounts left behind empty are not activity" do
    stub_snapshot(
      lamports: 0,
      token_accounts: [ token_account(mint: USDC_MINT, amount: "0", decimals: 6) ]
    )

    assert_not @adapter.has_activity?(ADDRESS)
  end

  test "detection asks once and does not retry a rate-limited node" do
    probe = stub_request(:post, Provider::SolanaRpc.url).to_return(status: 429, body: "rate limited")

    assert_not @adapter.has_activity?(ADDRESS)
    # Detection runs on the request thread: retrying with backoff here is what
    # turns one slow chain into a page that hangs.
    assert_requested probe, times: 1
  end

  private
    def with_asset_budget(tokens)
      previous = ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"]
      ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"] = tokens.to_s
      yield
    ensure
      ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"] = previous
    end

    def stub_token_list(tokens)
      stub_request(:get, /lite-api\.jup\.ag/)
        .to_return(status: 200, body: tokens.to_json, headers: json_headers)
    end

    def json_headers
      { "Content-Type" => "application/json" }
    end

    def token_account(mint:, amount:, decimals:, pubkey: TOKEN_ACCOUNT)
      {
        "pubkey" => pubkey,
        "account" => {
          "data" => {
            "parsed" => {
              "info" => { "mint" => mint, "tokenAmount" => { "amount" => amount, "decimals" => decimals } }
            }
          }
        }
      }
    end

    # One stub per RPC method, dispatched on the JSON-RPC method name so a single
    # endpoint can serve the whole snapshot.
    def stub_snapshot(lamports:, token_accounts:, signatures: [], transaction: nil)
      responses = {
        "getBalance" => { "value" => lamports },
        "getTokenAccountsByOwner" => { "value" => token_accounts },
        "getSignaturesForAddress" => signatures,
        "getTransaction" => transaction
      }

      stub_request(:post, Provider::SolanaRpc.url).to_return do |request|
        payload = JSON.parse(request.body)
        result = responses[payload["method"]]

        # Both token programs are asked; only the original one holds these
        # accounts, as it would on chain.
        if payload["method"] == "getTokenAccountsByOwner" &&
           payload.dig("params", 1, "programId") != Provider::SolanaRpc::TOKEN_PROGRAM_IDS.first
          result = { "value" => [] }
        end

        { status: 200, body: { "jsonrpc" => "2.0", "id" => 1, "result" => result }.to_json, headers: json_headers }
      end
    end

    def stub_rpc(method, result)
      stub_request(:post, Provider::SolanaRpc.url)
        .with(body: hash_including("method" => method))
        .to_return(status: 200, body: { "result" => result }.to_json, headers: json_headers)
    end
end
