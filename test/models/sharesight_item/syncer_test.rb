require "test_helper"

class SharesightItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @sync = @item.syncs.create!
  end

  test "a connection without its API client needs an update" do
    @item.update_columns(client_secret: nil)

    assert_raises(Provider::Sharesight::ConfigurationError) { SharesightItem::Syncer.new(@item).perform_sync(@sync) }
    assert @item.reload.requires_update?
  end

  test "flags portfolios that still need linking" do
    @item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42")
    @item.expects(:import_latest_data)
    @item.expects(:process_accounts).never

    SharesightItem::Syncer.new(@item).perform_sync(@sync)

    assert @item.reload.pending_account_setup?
  end

  test "a manual settlement account that took counterparts gets its own sync" do
    bank = @item.family.accounts.create!(name: "Macquarie CMA", balance: 0, currency: "AUD", accountable: Depository.new)
    account = @item.family.accounts.create!(name: "Shares", balance: 0, currency: "AUD", accountable: Investment.new)
    sharesight_account = @item.sharesight_accounts.create!(
      name: "Shares", sharesight_account_id: "42", currency: "AUD", current_balance: 2100, cash_balance: 0,
      raw_holdings_payload: [
        { "id" => 1, "quantity" => 20.0, "value" => 2100.0, "instrument_price" => 105.0,
          "instrument" => { "code" => "VAS", "market_code" => "ASX", "currency_code" => "AUD" }, "instrument_currency" => { "code" => "AUD" } }
      ],
      raw_trades_payload: [
        { "id" => 1, "transaction_type" => "BUY", "transaction_date" => "2026-09-01", "symbol" => "VAS", "market" => "ASX",
          "quantity" => 10, "price" => 100.0, "exchange_rate" => 1.0, "holding_id" => 1, "state" => "confirmed" }
      ],
      raw_payouts_payload: [],
      cash_mode: "settlement", settlement_account: bank
    )
    sharesight_account.ensure_account_provider!(account)
    Security.find_or_create_by!(ticker: "VAS", exchange_operating_mic: "XASX")

    @item.expects(:import_latest_data)
    SharesightItem::Syncer.new(@item).perform_sync(@sync)

    assert bank.entries.find_by(external_id: "sharesight_counterpart_#{sharesight_account.id}_trade_1"),
           "the router never booked the counterpart into the settlement account"
    assert bank.syncs.exists?, "the manual settlement account was never synced"
    assert account.syncs.exists?
  end
end
