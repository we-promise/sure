require "test_helper"
require_relative "../../../../support/onchain_capture_test_helper"

class Provider::AccountData::OnchainWallet::AssemblyTest < ActiveSupport::TestCase
  include OnchainCaptureTestHelper

  setup { travel_to Time.utc(2026, 9, 15, 12) }
  teardown { travel_back }

  test "Bitcoin retains exact units transfer direction and missing pending date" do
    source = wallet_source
    assembly = wallet_assembly(sources: [ source ])
    finish_assembly(assembly) do |operation|
      case operation["action"]
      when "bitcoin_summary" then bitcoin_summary
      when "bitcoin_history"
        [ { "txid" => "a" * 64, "vin" => [], "vout" => [ { "scriptpubkey_address" => BITCOIN_ADDRESS, "value" => 123456789 } ],
            "status" => { "block_time" => Time.utc(2026, 9, 14, 12).to_i } },
          { "txid" => "b" * 64, "vin" => [ { "prevout" => { "scriptpubkey_address" => BITCOIN_ADDRESS, "value" => 1 } } ], "vout" => [], "status" => {} } ]
      when "price" then daily_quote(date: operation.dig("arguments", "date"))
      else flunk operation["action"]
      end
    end
    snapshot = assembly.snapshots.values.sole
    assert_equal "2.0", snapshot.assets.sole["quantity"]
    assert_equal [ "1.23456789", "-0.00000001" ], snapshot.movements.map { |row| row["amount"] }
    assert_equal [ "2026-09-14", nil ], snapshot.movements.map { |row| row["date"] }
    assert_equal "current_sync_physical_responses", snapshot.payload.dig("evidence", "provenance")
    assert_equal [ "2026-09-14" ], assembly.quotes.values.sole.fetch("historical").keys
  end

  test "each registered EVM chain assembles summary and selected ERC20 once and preserves log identity" do
    Onchain::Chains.all.select { |definition| definition.token_kind == "erc20" }.each do |definition|
      token = wallet_source(chain: definition.key, kind: "erc20", contract: "0x#{'b' * 40}", symbol: "USDC")
      native = wallet_source(chain: definition.key)
      assembly = wallet_assembly(sources: [ native, token ])
      finish_assembly(assembly) do |operation|
        next disabled_quote if operation["action"] == "price"
        assert_equal "evm", operation["action"]
        case operation.dig("arguments", "resource")
        when "summary" then { "data" => { "coin_balance" => "1000000000000000001" }, "next_cursor" => nil }
        when "token_balances"
          { "data" => [ { "value" => "1234567", "token" => { "type" => "ERC-20", "address_hash" => token[:descriptor]["contract_address"],
            "symbol" => "USDC", "name" => "USD Coin", "decimals" => "6" } } ], "next_cursor" => nil }
        when "native_transfers" then { "data" => { "items" => [] }, "next_cursor" => nil }
        when "token_transfers"
          { "data" => { "items" => [ { "transaction_hash" => "tx", "log_index" => 7, "from" => { "hash" => EVM_ADDRESS }, "to" => { "hash" => "other" },
            "timestamp" => "2026-09-14T12:00:00Z", "total" => { "value" => "1234567", "decimals" => "6" },
            "token" => { "address_hash" => token[:descriptor]["contract_address"], "symbol" => "USDC" } } ] }, "next_cursor" => nil }
        end
      end
      snapshot = assembly.snapshots.values.sole
      assert_equal "1.000000000000000001", snapshot.assets.first["quantity"]
      assert_equal "1.234567", snapshot.asset_for(token[:descriptor])["quantity"]
      assert_equal "tx_7", snapshot.movements.sole["external_id"]
      assert_equal "-1.234567", snapshot.movements.sole["amount"]
      assert_equal 1, assembly.operations.count { |row| row.dig("operation", "arguments", "resource") == "summary" }
    end
  end

  test "keyed Etherscan changes only history backend and full page budget remains incomplete" do
    source = wallet_source(chain: Onchain::Chains::ETHEREUM)
    assembly = wallet_assembly(sources: [ source ], configuration: wallet_configuration(history_pages: 1), keyed_history: true)
    finish_assembly(assembly) do |operation|
      case operation["action"]
      when "evm"
        assert_includes %w[summary token_balances], operation.dig("arguments", "resource")
        { "data" => operation.dig("arguments", "resource") == "summary" ? { "coin_balance" => "0" } : [], "next_cursor" => nil }
      when "etherscan" then { "rows" => [], "complete" => false }
      when "price" then disabled_quote
      end
    end
    assert assembly.snapshots.values.sole.history_truncated?
    assert_equal 2, assembly.operations.count { |row| row.dig("operation", "action") == "etherscan" }
  end

  test "Solana combines both programs verified metadata and exact mint transfer identity" do
    mint = "B" * 44
    token = wallet_source(chain: Onchain::Chains::SOLANA, kind: "spl", contract: mint, symbol: "verified")
    native = wallet_source(chain: Onchain::Chains::SOLANA)
    signature = "c" * 88
    assembly = wallet_assembly(sources: [ native, token ])
    token_calls, signature_calls = 0, 0
    finish_assembly(assembly) do |operation|
      case operation["action"]
      when "solana_balance" then { "value" => 1_000_000_000 }
      when "solana_tokens"
        token_calls += 1
        { "value" => [ { "pubkey" => "#{token_calls == 1 ? 'D' : 'E'}" * 44, "account" => { "data" => { "parsed" => { "info" => {
          "owner" => SOLANA_ADDRESS, "mint" => mint, "tokenAmount" => { "amount" => "1234567", "decimals" => 6 }
        } } } } } ] }
      when "token_metadata" then [ { "id" => mint, "symbol" => "VERIFIED", "name" => "Verified token", "isVerified" => true } ]
      when "solana_signatures"
        signature_calls += 1
        [ { "signature" => signature, "slot" => 10, "err" => nil,
          "confirmationStatus" => signature_calls == 1 ? "processed" : "finalized",
          "blockTime" => signature_calls == 1 ? nil : Time.utc(2026, 9, 14).to_i } ]
      when "solana_transaction"
        { "transaction" => { "message" => { "accountKeys" => [ SOLANA_ADDRESS ] } }, "meta" => { "err" => nil,
          "preBalances" => [ 1_000_000_000 ], "postBalances" => [ 999_999_000 ], "preTokenBalances" => [],
          "postTokenBalances" => [ { "owner" => SOLANA_ADDRESS, "mint" => mint, "uiTokenAmount" => { "amount" => "1234567", "decimals" => 6 } } ] } }
      when "price" then disabled_quote
      else flunk operation["action"]
      end
    end
    snapshot = assembly.snapshots.values.sole
    assert_equal 2, token_calls
    assert_equal "2.469134", snapshot.asset_for(token[:descriptor])["quantity"]
    assert_equal "VERIFIED", snapshot.asset_for(token[:descriptor])["symbol"]
    assert_equal "#{signature}_#{mint}", snapshot.movements.sole["external_id"]
    assert_equal "2026-09-14", snapshot.movements.sole["date"]
    assert_equal 1, assembly.operations.count { |row| row.dig("operation", "action") == "solana_transaction" }
    refute snapshot.history_truncated?
  end

  test "unknown Solana tokens cannot borrow copied ticker and missing transaction is explicitly incomplete" do
    mint = "B" * 44
    source = wallet_source(chain: Onchain::Chains::SOLANA, kind: "spl", contract: mint, symbol: "BTC")
    assembly = wallet_assembly(sources: [ source ])
    finish_assembly(assembly) do |operation|
      case operation["action"]
      when "solana_balance" then { "value" => 0 }
      when "solana_tokens"
        { "value" => operation.dig("arguments", "program_id") == Provider::SolanaRpc::TOKEN_PROGRAM_IDS.first ? [ {
          "pubkey" => "D" * 44, "account" => { "data" => { "parsed" => { "info" => { "owner" => SOLANA_ADDRESS, "mint" => mint,
            "tokenAmount" => { "amount" => "1", "decimals" => 6 } } } } } } ] : [] }
      when "token_metadata" then [ { "id" => mint, "symbol" => "BTC", "isVerified" => false } ]
      when "solana_signatures" then [ { "signature" => "c" * 88, "blockTime" => Time.current.to_i } ]
      when "solana_transaction" then nil
      else flunk "Unknown token must not issue price query"
      end
    end
    assert assembly.snapshots.values.sole.history_truncated?
    assert_nil assembly.quotes.values.sole["ticker"]
    assert_nil assembly.quotes.values.sole["current"]
  end

  test "exact quoted day and actual cached FX day are retained without currency relabeling" do
    [ { "rate" => "0.9", "date" => "2026-09-14" }, nil ].each do |fx|
      source = wallet_source(currency: "EUR")
      assembly = wallet_assembly(sources: [ source ])
      finish_assembly(assembly) do |operation|
        case operation["action"]
        when "bitcoin_summary" then bitcoin_summary
        when "bitcoin_history" then []
        when "price" then daily_quote(date: operation.dig("arguments", "date"))
        when "fx" then fx
        when "fx_remote"
          { "version" => 1, "provider" => Wallet::FxConfiguration.credentials.fetch("provider"), "request" => operation.fetch("arguments"),
            "http_status" => nil, "status" => "credential_unavailable", "response" => {} }
        end
      end
      quote = assembly.quotes.values.sole
      assert_equal "EUR", quote["currency"]
      if fx
        assert_equal "45000.0", quote.dig("current", "price")
        assert_equal "2026-09-15", quote.dig("current", "date")
        assert_equal "2026-09-14", quote.dig("current", "fx_date")
        assert_equal "USD", quote.dig("current", "original_currency")
      else
        assert_nil quote["current"]
      end
    end
  end

  test "response replay rejects an altered operation duplicate slot and backwards physical clock" do
    source = wallet_source
    assembly = wallet_assembly(sources: [ source ])
    operation = assembly.next_operation
    assert_raises(ArgumentError) { assembly.accept!(operation: operation.merge("address" => "other"), response: bitcoin_summary, fetched_at: Time.current.iso8601(9)) }
    assert_raises(ArgumentError) { assembly.accept!(operation: operation, response: bitcoin_summary, fetched_at: 1.second.ago.iso8601(9)) }
    assembly.accept!(operation: operation, response: bitcoin_summary, fetched_at: Time.current.iso8601(9))
    assert_raises(ArgumentError) { assembly.accept!(operation: operation, response: bitcoin_summary, fetched_at: Time.current.iso8601(9)) }
  end

  test "retained uppercase Bech32 spelling keeps its identity and matches canonical explorer outputs" do
    source = wallet_source
    address = "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4"
    source[:descriptor]["wallet_address"] = address
    source[:external][:external_id] = Wallet::SourceDescriptor.external_id(source[:descriptor])
    assembly = wallet_assembly(sources: [ source ])
    finish_assembly(assembly) do |operation|
      case operation["action"]
      when "bitcoin_summary" then bitcoin_summary
      when "bitcoin_history"
        [ { "txid" => "a" * 64, "vin" => [], "vout" => [ { "scriptpubkey_address" => address.downcase, "value" => 1 } ],
          "status" => { "block_time" => Time.current.to_i } } ]
      when "price" then disabled_quote
      end
    end
    snapshot = assembly.snapshots.values.sole
    assert_equal address, snapshot.address
    assert_equal "0.00000001", snapshot.movements.sole["amount"]
    assert_equal source[:external][:external_id], Wallet::SourceDescriptor.external_id(source[:descriptor])
  end

  test "Solana unqueried held token accounts keep history incomplete even with empty signature pages" do
    source = wallet_source(chain: Onchain::Chains::SOLANA)
    assembly = wallet_assembly(sources: [ source ], configuration: wallet_configuration(asset_tokens: 1))
    finish_assembly(assembly) do |operation|
      case operation["action"]
      when "solana_balance" then { "value" => 0 }
      when "solana_tokens"
        rows = if operation.dig("arguments", "program_id") == Provider::SolanaRpc::TOKEN_PROGRAM_IDS.first
          7.times.map do |index|
            { "pubkey" => ("D" * 42) + index.to_s, "account" => { "data" => { "parsed" => { "info" => {
              "owner" => SOLANA_ADDRESS, "mint" => index == 6 ? "C" * 44 : "B" * 44, "tokenAmount" => { "amount" => "1", "decimals" => 6 }
            } } } } }
          end
        else
          []
        end
        { "value" => rows }
      when "token_metadata" then []
      when "solana_signatures" then []
      when "price" then disabled_quote
      end
    end
    assert assembly.snapshots.values.sole.history_truncated?
    assert assembly.snapshots.values.sole.assets_truncated?
    assert_equal 6, assembly.operations.count { |row| row.dig("operation", "action") == "solana_signatures" }
  end

  test "Solana duplicate signature observations reject conflicting stable slots" do
    source = wallet_source(chain: Onchain::Chains::SOLANA)
    assembly = wallet_assembly(sources: [ source ])
    error = assert_raises(ArgumentError) do
      finish_assembly(assembly) do |operation|
        case operation["action"]
        when "solana_balance" then { "value" => 0 }
        when "solana_tokens" then { "value" => [] }
        when "solana_signatures"
          [ { "signature" => "c" * 88, "slot" => 10 }, { "signature" => "c" * 88, "slot" => 11 } ]
        else flunk "Conflicting signature must fail before transaction or price requests"
        end
      end
    end
    assert error
  end
end
