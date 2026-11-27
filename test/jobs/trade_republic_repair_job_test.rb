require "test_helper"

class TradeRepublicRepairJobTest < ActiveJob::TestCase
  test "skips provider accounts linked to a disabled account" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all
    provider_account = item.trade_republic_accounts.create!(
      name: "Trade Republic Crypto", kind: "crypto", trade_republic_account_id: "crypto:DE1", currency: "EUR"
    )
    account = item.family.accounts.create!(
      name: "Trade Republic Crypto", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "exchange")
    )
    provider_account.ensure_account_provider!(account)
    account.disable!

    TradeRepublicAccount::Processor.expects(:new).never

    TradeRepublicRepairJob.perform_now(item)
  end

  test "a repair reaches the cached exchange rate notes" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all
    provider_account = item.trade_republic_accounts.create!(
      name: "Trade Republic Cash", kind: "cash", trade_republic_account_id: "CASH:DE1", currency: "EUR"
    )
    account = item.family.accounts.create!(name: "Trade Republic Cash", balance: 0, currency: "EUR", accountable: Depository.new)
    provider_account.ensure_account_provider!(account)
    assert_not_includes item.family.currencies_without_exchange_rate, "SEK"
    provider_account.update!(raw_timeline_payload: [
      { id: "evt_sek", timestamp: "2026-08-01T10:00:00Z", category: "PAYMENT_RECEIVED", detail: { amount: "500.00", currency: "SEK" } }
    ])

    TradeRepublicRepairJob.perform_now(item)

    assert account.entries.where(currency: "SEK").exists?
    assert_includes Family.find(item.family.id).currencies_without_exchange_rate, "SEK"
  end

  test "a repair whose broadcast fails after its writes still moves sync activity" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all
    provider_account = item.trade_republic_accounts.create!(
      name: "Trade Republic Cash", kind: "cash", trade_republic_account_id: "CASH:DE1", currency: "EUR"
    )
    account = item.family.accounts.create!(name: "Trade Republic Cash", balance: 0, currency: "EUR", accountable: Depository.new)
    provider_account.ensure_account_provider!(account)
    provider_account.update!(raw_timeline_payload: [
      { id: "evt_sek", timestamp: "2026-08-01T10:00:00Z", category: "PAYMENT_RECEIVED", detail: { amount: "500.00", currency: "SEK" } }
    ])
    Account.any_instance.stubs(:broadcast_sync_complete).raises(StandardError, "broadcast failed")

    assert_changes -> { item.family.reload.latest_sync_activity_at } do
      TradeRepublicRepairJob.perform_now(item)
    end
    assert account.entries.where(currency: "SEK").exists?, "precondition: the repair committed its writes"
  end

  test "a repair that processes no account leaves sync activity alone" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all

    assert_no_changes -> { item.family.reload.latest_sync_activity_at } do
      TradeRepublicRepairJob.perform_now(item)
    end
  end
end
