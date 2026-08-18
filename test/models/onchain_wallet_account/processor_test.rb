# frozen_string_literal: true

require "test_helper"

class OnchainWalletAccount::ProcessorTest < ActiveSupport::TestCase
  include OnchainTestHelper

  setup do
    register_fake_chain!
    @family = families(:dylan_family)
    @item = create_onchain_wallet_item(family: @family)
    @onchain_account = create_onchain_wallet_account(item: @item, asset: fake_native_asset(quantity: 2))
    @account = link_onchain_wallet_account!(@onchain_account)
  end

  teardown do
    unregister_fake_chain!
  end

  test "creates a holding and sets the account balance from the current price" do
    price_asset_at(Date.current, 100)

    assert_difference "@account.holdings.count", 1 do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    holding = @account.holdings.order(:created_at).last
    assert_equal 2, holding.qty
    assert_equal 200, holding.amount
    assert_equal 200, @account.reload.balance
    assert_equal 0, @account.cash_balance
    assert_equal 200, @onchain_account.reload.current_balance
  end

  test "tracks quantity but values the asset at zero when no price is known" do
    OnchainWalletAccount::Processor.new(@onchain_account).process

    holding = @account.holdings.order(:created_at).last
    assert_equal 2, holding.qty
    assert_equal 0, holding.amount
    assert_equal 0, @account.reload.balance
  end

  test "records why an asset ended up valued at zero when crypto pricing is off" do
    assert_difference "DebugLogEntry.count", 1 do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "onchain_wallet", entry.provider_key
    assert_equal @family, entry.family
    assert_equal "CRYPTO:FAKE", entry.metadata["ticker"]
  end

  test "a merely missing price is not reported as a configuration problem" do
    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])
    Security.any_instance.stubs(:price_data_provider).returns(nil)

    assert_no_difference "DebugLogEntry.count" do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end
  end

  test "creates no holding when the symbol cannot be a ticker" do
    @onchain_account.update_columns(symbol: "Visit site to claim rewards")

    assert_no_difference "Holding.count" do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    assert_equal 0, @account.reload.balance
  end

  test "materializes an inbound movement as a Buy trade when that day's price is known" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))

    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx1")
    assert_equal "Trade", entry.entryable_type
    assert_equal BigDecimal("1.5"), entry.entryable.qty
    assert_equal 50, entry.entryable.price
    assert_equal(-75, entry.amount)
    assert_equal "Buy", entry.entryable.investment_activity_label
    assert_not entry.excluded
  end

  test "materializes an outbound movement as a Sell trade" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    store_movements(fake_movement(external_id: "tx2", amount: "-1", timestamp: date))

    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx2")
    assert_equal(-1, entry.entryable.qty)
    assert_equal 50, entry.amount
    assert_equal "Sell", entry.entryable.investment_activity_label
  end

  test "materializes a display-only excluded entry when that day's price is unknown" do
    date = 3.days.ago.to_date
    store_movements(fake_movement(external_id: "tx3", amount: "1.5", timestamp: date))

    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx3")
    assert_equal "Transaction", entry.entryable_type
    assert_equal 0, entry.amount
    assert entry.excluded
    assert_equal "1.5", entry.entryable.extra.dig("onchain_wallet", "amount")
  end

  test "a movement priced on another date does not become a trade" do
    date = 3.days.ago.to_date
    price_asset_at(Date.current, 100)
    store_movements(fake_movement(external_id: "tx4", amount: "1", timestamp: date))

    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx4")
    assert_equal "Transaction", entry.entryable_type
    assert entry.excluded
  end

  test "processing twice does not duplicate holdings or entries" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    price_asset_at(Date.current, 60)
    store_movements(
      fake_movement(external_id: "tx1", amount: "1", timestamp: date),
      fake_movement(external_id: "tx2", amount: "1", timestamp: 2.days.ago.to_date)
    )

    OnchainWalletAccount::Processor.new(@onchain_account).process

    assert_no_difference [ "Holding.count", "Entry.count" ] do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end
  end

  test "backfills missing prices in one batched provider call so cost basis reconstructs" do
    date = 5.days.ago.to_date
    store_movements(fake_movement(external_id: "tx1", amount: "1", timestamp: date))
    Security.any_instance.stubs(:price_data_provider).returns(Provider::BinancePublic.new)
    Security.any_instance.expects(:import_provider_prices).with(start_date: date, end_date: Date.current).once.returns([ 0, nil ])

    OnchainWalletAccount::Processor.new(@onchain_account).process
  end

  test "does not backfill when every needed price is already known" do
    date = 5.days.ago.to_date
    price_asset_at(date, 50)
    price_asset_at(Date.current, 60)
    store_movements(fake_movement(external_id: "tx1", amount: "1", timestamp: date))
    Security.any_instance.stubs(:price_data_provider).returns(Provider::BinancePublic.new)
    Security.any_instance.expects(:import_provider_prices).never

    OnchainWalletAccount::Processor.new(@onchain_account).process
  end

  test "does not reach for prices at all when no crypto price provider is enabled" do
    store_movements(fake_movement(external_id: "tx1", amount: "1", timestamp: 5.days.ago.to_date))
    Security.any_instance.expects(:import_provider_prices).never

    OnchainWalletAccount::Processor.new(@onchain_account).process

    assert_equal 0, @account.reload.balance
  end

  test "a failing price provider does not stop the holding from being written" do
    store_movements(fake_movement(external_id: "tx1", amount: "1", timestamp: 5.days.ago.to_date))
    Security.any_instance.stubs(:price_data_provider).returns(Provider::BinancePublic.new)
    Security.any_instance.stubs(:import_provider_prices).raises(StandardError, "provider down")

    assert_difference "Holding.count", 1 do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    assert_includes DebugLogEntry.pluck(:message).join(" "), "Could not backfill"
  end

  test "does nothing when the asset is not linked to an account" do
    unlinked = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))

    assert_nothing_raised do
      OnchainWalletAccount::Processor.new(unlinked).process
    end
  end

  private
    def security
      @security ||= Onchain::SecurityResolver.resolve(symbol: @onchain_account.symbol, name: @onchain_account.name)
    end

    def price_asset_at(date, price)
      Security::Price.create!(security: security, date: date, price: price, currency: "USD")
    end

    def store_movements(*movements)
      @onchain_account.update!(
        raw_movements_payload: {
          "movements" => movements.map do |movement|
            {
              "external_id" => movement.external_id,
              "symbol" => movement.symbol,
              "contract" => movement.contract_key,
              "amount" => movement.amount.to_s("F"),
              "date" => movement.date.to_s
            }
          end
        }
      )
    end
end
