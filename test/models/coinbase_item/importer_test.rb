# frozen_string_literal: true

require "test_helper"

class CoinbaseItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = CoinbaseItem.create!(
      family: families(:dylan_family),
      name: "Coinbase",
      api_key: "key",
      api_secret: "secret"
    )
  end

  test "persists an eighteen-decimal Coinbase asset balance after reload" do
    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ btc_account_payload ])
    provider.expects(:get_transactions).with("cb_btc_123", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT).returns([])

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_btc_123")
    assert_equal BigDecimal("0.000000000000000148"), coinbase_account.current_balance
  end

  test "still saves the fetched balance when the transactions fetch is rate limited" do
    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ btc_account_payload ])
    # RateLimitError is a sibling of ApiError, not a subclass, so it has to be
    # rescued explicitly in fetch_and_store_transactions or it propagates past
    # coinbase_account.save!, silently skipping this account's balance update
    # for the whole sync even though the balance above was fetched correctly.
    provider.expects(:get_transactions)
      .with("cb_btc_123", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT)
      .raises(Provider::Coinbase::RateLimitError, "Rate limit exceeded")

    result = CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import
    assert result[:success]

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_btc_123")
    assert_equal BigDecimal("0.000000000000000148"), coinbase_account.current_balance
  end

  test "fetches transaction history even for a zero-balance, non-USD wallet" do
    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ zero_balance_account_payload ])
    # A wallet that was fully sold or transferred out reports a zero balance
    # but still needs its history fetched to reconstruct realized gains --
    # a zero balance here says nothing about whether that history exists.
    provider.expects(:get_transactions)
      .with("cb_eth_zero", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT)
      .returns([ { "id" => "txn_1" } ])

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_eth_zero")
    assert_equal [ { "id" => "txn_1" } ], coinbase_account.raw_transactions_payload["transactions"]
  end

  test "stores a rate-limited partial fetch when there is no previous history to merge with" do
    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ btc_account_payload ])
    partial = [ { "id" => "txn_a" }, { "id" => "txn_b" } ]
    provider.expects(:get_transactions)
      .with("cb_btc_123", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT)
      .raises(Provider::Coinbase::PartialResultError.new("Rate limit exceeded", partial))

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_btc_123")
    assert_equal partial, coinbase_account.raw_transactions_payload["transactions"]
    assert coinbase_account.raw_transactions_payload["truncated"]
  end

  test "keeps previously-stored transactions a smaller rate-limited fetch didn't reach" do
    @item.coinbase_accounts.create!(
      account_id: "cb_btc_123",
      name: "BTC Wallet",
      currency: "BTC",
      current_balance: BigDecimal("0.000000000000000148"),
      raw_transactions_payload: { "transactions" => [ { "id" => "txn_a" }, { "id" => "txn_b" }, { "id" => "txn_c" } ] }
    )

    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ btc_account_payload ])
    provider.expects(:get_transactions)
      .with("cb_btc_123", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT)
      .raises(Provider::Coinbase::PartialResultError.new("Rate limit exceeded", [ { "id" => "txn_a" } ]))

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_btc_123")
    assert_equal 3, coinbase_account.raw_transactions_payload["transactions"].size
  end

  test "merges new transactions from a rate-limited partial fetch instead of losing them to a size comparison" do
    @item.coinbase_accounts.create!(
      account_id: "cb_btc_123",
      name: "BTC Wallet",
      currency: "BTC",
      current_balance: BigDecimal("0.000000000000000148"),
      raw_transactions_payload: { "transactions" => [ { "id" => "txn_a" }, { "id" => "txn_b" }, { "id" => "txn_c" } ] }
    )

    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ btc_account_payload ])
    # Transactions are newest-first, so a partial fetch that only got through
    # the first page can be *smaller* than the stored history while still
    # containing a genuinely new transaction the stored history doesn't have.
    # Comparing sizes to decide whether to keep it would lose txn_new here.
    provider.expects(:get_transactions)
      .with("cb_btc_123", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT)
      .raises(Provider::Coinbase::PartialResultError.new("Rate limit exceeded", [ { "id" => "txn_new" } ]))

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_btc_123")
    ids = coinbase_account.raw_transactions_payload["transactions"].map { |t| t["id"] }
    assert_equal %w[txn_a txn_b txn_c txn_new].sort, ids.sort
  end

  test "includes the linked account_provider in a transactions-fetch DebugLogEntry" do
    coinbase_account = @item.coinbase_accounts.create!(
      account_id: "cb_btc_123",
      name: "BTC Wallet",
      currency: "BTC",
      current_balance: 0
    )
    account = @item.family.accounts.create!(
      name: "Coinbase BTC",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    account_provider = AccountProvider.create!(account: account, provider: coinbase_account)

    provider = mock("coinbase provider")
    provider.expects(:get_accounts).returns([ btc_account_payload ])
    provider.expects(:get_transactions)
      .with("cb_btc_123", limit: CoinbaseItem::Importer::FULL_HISTORY_LIMIT)
      .raises(Provider::Coinbase::RateLimitError, "Rate limit exceeded")

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    entry = DebugLogEntry.last
    assert_equal account_provider, entry.account_provider
  end

  test "quantity columns preserve sixteen integer and eighteen fractional digits" do
    assert_quantity_precision CoinbaseAccount, "current_balance", nullable: true
    assert_quantity_precision Holding, "qty", nullable: false
    assert_quantity_precision Trade, "qty", nullable: true
  end

  private

    def btc_account_payload
      {
        "id" => "cb_btc_123",
        "name" => "BTC Wallet",
        "type" => "wallet",
        "status" => "active",
        "balance" => { "amount" => "0.000000000000000148", "currency" => "BTC" },
        "currency" => { "code" => "BTC", "name" => "Bitcoin", "type" => "crypto" }
      }
    end

    def zero_balance_account_payload
      {
        "id" => "cb_eth_zero",
        "name" => "ETH Wallet",
        "type" => "wallet",
        "status" => "active",
        "balance" => { "amount" => "0", "currency" => "ETH" },
        "currency" => { "code" => "ETH", "name" => "Ethereum", "type" => "crypto" }
      }
    end

    def assert_quantity_precision(model, column_name, nullable:)
      column = model.columns_hash.fetch(column_name)

      assert_equal 34, column.precision
      assert_equal 18, column.scale
      assert_equal nullable, column.null
    end
end
