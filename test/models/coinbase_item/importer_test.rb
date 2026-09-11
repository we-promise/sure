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
    provider.expects(:get_transactions).with("cb_btc_123", limit: 100).returns([])

    CoinbaseItem::Importer.new(@item, coinbase_provider: provider).import

    coinbase_account = @item.coinbase_accounts.find_by!(account_id: "cb_btc_123")
    assert_equal BigDecimal("0.000000000000000148"), coinbase_account.current_balance
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

    def assert_quantity_precision(model, column_name, nullable:)
      column = model.columns_hash.fetch(column_name)

      assert_equal 34, column.precision
      assert_equal 18, column.scale
      assert_equal nullable, column.null
    end
end
