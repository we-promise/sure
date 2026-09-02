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

  test "a non-USD asset with no exchange rate provider says so instead of just showing zero" do
    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])
    Security.any_instance.stubs(:price_data_provider).returns(nil)
    ExchangeRate.stubs(:provider).returns(nil)
    @onchain_account.update!(currency: "EUR")

    assert_difference "DebugLogEntry.count", 1 do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "exchange_rate" ], entry.metadata["reasons"]
    assert_equal "EUR", entry.metadata["currency"]
    assert_equal 0, @account.reload.balance
  end

  test "creates no holding when the symbol cannot be a ticker" do
    @onchain_account.update_columns(symbol: "Visit site to claim rewards")

    assert_no_difference "Holding.count" do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    assert_equal 0, @account.reload.balance
  end

  test "materializes an inbound movement as a priced transfer when that day's price is known" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))

    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx1")
    assert_equal "Trade", entry.entryable_type
    assert_equal BigDecimal("1.5"), entry.entryable.qty
    assert_equal 50, entry.entryable.price
    assert_equal(-75, entry.amount)
    # A trade is the shape this ledger needs to carry quantity and cost basis,
    # but coins arriving at an address were not bought here — and the name is
    # the one the movement already had before a price existed for it, so it does
    # not change the day one turns up.
    assert_equal "Transfer", entry.entryable.investment_activity_label
    assert_not entry.excluded
    assert_equal "Received 1.5 FAKE", entry.name
  end

  test "materializes an outbound movement as a priced transfer out" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    store_movements(fake_movement(external_id: "tx2", amount: "-1", timestamp: date))

    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx2")
    assert_equal(-1, entry.entryable.qty)
    assert_equal 50, entry.amount
    assert_equal "Transfer", entry.entryable.investment_activity_label
    assert_equal "Sent 1.0 FAKE", entry.name
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

  test "a movement priced only on a later sync does not collide with its display-only entry" do
    date = 3.days.ago.to_date
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))

    # First sync: no price for that day, so the movement is display-only.
    OnchainWalletAccount::Processor.new(@onchain_account).process
    assert_equal "Transaction", onchain_entry("tx1").entryable_type

    # Second sync, with the price now known and the wallet having moved. This
    # used to raise, taking the whole item sync — and the repair pass that runs
    # after it — down with it.
    price_asset_at(date, 40)
    @onchain_account.update!(quantity: 3)

    assert_nothing_raised do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    entry = onchain_entry("tx1")
    assert_equal "Trade", entry.entryable_type
    assert_equal BigDecimal("1.5"), entry.entryable.qty
    assert_equal(-60, entry.amount)
    assert_equal 1, @account.entries.where(external_id: entry.external_id).count
  end

  test "a failed trade write does not lose the transfer it was replacing" do
    date = 3.days.ago.to_date
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))
    OnchainWalletAccount::Processor.new(@onchain_account).process
    price_asset_at(date, 40)

    Account::ProviderImportAdapter.any_instance.stubs(:import_trade).raises(ActiveRecord::RecordInvalid.new(Entry.new))

    assert_raises ActiveRecord::RecordInvalid do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    # The display-only entry is still there rather than having been dropped in
    # favour of a trade that never landed.
    assert_equal "Transaction", onchain_entry("tx1").entryable_type
  end

  test "a display-only movement becomes a trade once its price is known" do
    date = 3.days.ago.to_date
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))
    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = onchain_entry("tx1")
    assert_equal "Transaction", entry.entryable_type

    price_asset_at(date, 40)

    assert_equal 1, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements

    upgraded = onchain_entry("tx1")
    assert_equal "Trade", upgraded.entryable_type
    assert_equal entry.external_id, upgraded.external_id
    assert_equal BigDecimal("1.5"), upgraded.entryable.qty
    assert_equal 40, upgraded.entryable.price
    assert_equal(-60, upgraded.amount)
    assert_not upgraded.excluded
  end

  test "the repair leaves a movement alone while its price is still unknown" do
    store_movements(fake_movement(external_id: "tx1", amount: "1", timestamp: 3.days.ago.to_date))
    OnchainWalletAccount::Processor.new(@onchain_account).process

    assert_equal 0, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements
    assert_equal "Transaction", onchain_entry("tx1").entryable_type
  end

  # Movements imported before transfers were called transfers keep their `Buy`
  # label and their "Buy 1.5 shares of ..." name. Nothing rewrote them: an
  # ordinary sync returns early when no address changed on chain, and the
  # repair only ever looked at display-only Transaction rows — so a cold
  # wallet would show the old wording indefinitely.
  test "the repair relabels a trade imported before transfers were named" do
    date = 3.days.ago.to_date
    price_asset_at(date, 40)
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))
    OnchainWalletAccount::Processor.new(@onchain_account).process

    entry = onchain_entry("tx1")
    entry.entryable.update!(investment_activity_label: "Buy")
    entry.update!(name: "Buy 1.5 shares of CRYPTO:FAKE")

    assert_equal 1, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements

    repaired = onchain_entry("tx1")
    assert_equal "Transfer", repaired.entryable.investment_activity_label
    assert_no_match(/shares/, repaired.name)
  end

  # Idempotent, so a wallet that syncs nightly does not rewrite the same rows
  # forever — and the "no writes" test above stays honest.
  test "the repair leaves an already-correct trade alone" do
    date = 3.days.ago.to_date
    price_asset_at(date, 40)
    store_movements(fake_movement(external_id: "tx1", amount: "1.5", timestamp: date))
    OnchainWalletAccount::Processor.new(@onchain_account).process

    assert_equal 0, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements
  end

  # A trade the user entered by hand is not this processor's to rename.
  test "the repair does not touch a trade it did not import" do
    manual = @account.entries.create!(
      name: "Bought some elsewhere", date: 2.days.ago.to_date, amount: -50, currency: "USD",
      entryable: Trade.new(security: security, qty: 1, price: 50, currency: "USD",
                           investment_activity_label: "Buy")
    )

    OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements

    assert_equal "Buy", manual.reload.entryable.investment_activity_label
    assert_equal "Bought some elsewhere", manual.name
  end
  test "the repair writes nothing when there is nothing to upgrade" do
    price_asset_at(Date.current, 100)
    OnchainWalletAccount::Processor.new(@onchain_account).process

    assert_no_difference [ "Entry.count", "Holding.count" ] do
      assert_equal 0, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements
    end
  end

  test "the repair does not touch another provider's excluded entries" do
    foreign = @account.entries.create!(
      date: 3.days.ago.to_date, amount: 0, currency: @account.currency, name: "Manual note",
      excluded: true, external_id: "#{@onchain_account.id}_manual", source: "kraken",
      entryable: Transaction.new
    )

    assert_equal 0, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements
    assert_equal "Transaction", foreign.reload.entryable_type
  end

  test "a malformed stored amount costs its movement, not the whole asset" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    @onchain_account.update!(
      raw_movements_payload: {
        "movements" => [
          { "external_id" => "junk", "symbol" => "FAKE", "contract" => nil, "amount" => "not-a-number", "date" => date.to_s },
          { "external_id" => "good", "symbol" => "FAKE", "contract" => nil, "amount" => "2", "date" => date.to_s }
        ]
      }
    )

    assert_nothing_raised do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    assert_nil @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_junk")
    assert_equal "Trade", onchain_entry("good").entryable_type
  end

  test "NaN and the infinities are rejected, not carried into a trade" do
    date = 3.days.ago.to_date
    price_asset_at(date, 50)
    movements = [ "NaN", "Infinity", "-Infinity" ].each_with_index.map do |amount, index|
      { "external_id" => "tx#{index}", "symbol" => "FAKE", "contract" => nil, "amount" => amount, "date" => date.to_s }
    end
    movements << { "external_id" => "good", "symbol" => "FAKE", "contract" => nil, "amount" => "2", "date" => date.to_s }
    @onchain_account.update!(raw_movements_payload: { "movements" => movements })

    assert_nothing_raised do
      OnchainWalletAccount::Processor.new(@onchain_account).process
    end

    # BigDecimal parses all three and none of them is zero, so only an explicit
    # finite check keeps them out.
    3.times { |index| assert_nil @account.entries.find_by(external_id: "onchain_#{@onchain_account.id}_tx#{index}") }
    assert_equal "Trade", onchain_entry("good").entryable_type
  end

  test "the repair pass survives a malformed stored amount too" do
    date = 3.days.ago.to_date
    store_movements(fake_movement(external_id: "tx1", amount: "1", timestamp: date))
    OnchainWalletAccount::Processor.new(@onchain_account).process
    entry = onchain_entry("tx1")
    entry.entryable.update!(extra: { "onchain_wallet" => { "amount" => "not-a-number", "date" => date.to_s } })
    price_asset_at(date, 50)

    assert_nothing_raised do
      assert_equal 0, OnchainWalletAccount::Processor.new(@onchain_account).repair_display_only_movements
    end
  end

  test "does nothing when the asset is not linked to an account" do
    unlinked = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))

    assert_nothing_raised do
      OnchainWalletAccount::Processor.new(unlinked).process
    end
  end

  private
    def onchain_entry(movement_id)
      @account.entries.find_by!(external_id: "onchain_#{@onchain_account.id}_#{movement_id}")
    end

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
