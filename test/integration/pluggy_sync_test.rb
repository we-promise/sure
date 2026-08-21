# frozen_string_literal: true

require "test_helper"

# T22 — end-to-end Pluggy sync happy path. Drives a REAL Sync record through
# `sync.perform` → Syncable#perform_sync → PluggyItem::Syncer#perform_sync →
# PluggyItem::Importer → PluggyAccount::Processor → Account::ProviderImportAdapter,
# stubbed ONLY at the PluggyItem#pluggy_provider boundary (the live Pluggy SDK).
# Proves the chain lands a real Transaction entry (banking) and a real Holding
# (investment) on linked Account fixtures, with Pluggy's sign convention negated
# to Sure's (positive = money-out) by PluggyAccount::Transactions::Processor.
class PluggySyncTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @depository = accounts(:depository) # Depository, dylan_family
    @investment = accounts(:investment) # Investment, dylan_family

    # Fresh item so the success transition (requires_update → good) is observable.
    @pluggy_item = PluggyItem.create!(
      family: families(:dylan_family),
      name: "E2E Pluggy",
      client_id: "test_client",
      client_secret: "test_secret",
      pluggy_item_id: "item-e2e",
      status: :requires_update
    )

    # Pre-create + pre-link the two PluggyAccounts so PluggyAccount::Processor#process
    # does not early-return (requires pluggy_account.current_account present via
    # AccountProvider). Importer#upsert_from_pluggy! later finds these by
    # pluggy_account_id (unique index) and updates snapshots in place, so the
    # linkage survives and the real Importer → Processor → adapter chain runs.
    @bank_pa = PluggyAccount.create!(
      pluggy_item: @pluggy_item,
      pluggy_account_id: "bank-1",
      name: "Checking",
      currency: "BRL"
    )
    AccountProvider.create!(account: @depository, provider: @bank_pa)

    @inv_pa = PluggyAccount.create!(
      pluggy_item: @pluggy_item,
      pluggy_account_id: "inv-1",
      name: "Brokerage",
      currency: "BRL"
    )
    AccountProvider.create!(account: @investment, provider: @inv_pa)

    # Provider boundary stub (the live Pluggy SDK). The investment payload is
    # holding-shaped per the Importer: investments_data is iterated for
    # get_investment_transactions(investment_id:) AND snapshotted as the
    # holdings_payload on the investment-typed account (Trades = phase 2, empty).
    @provider = stub("PluggyProvider")
    @provider.stubs(:get_item).returns({ "connector" => { "name" => "Test Bank", "website_url" => "https://test.bank" } })
    @provider.stubs(:get_investments).returns(investments_payload)
    @provider.stubs(:get_investment_transactions).returns([])
    @provider.stubs(:get_accounts).returns(accounts_payload)
    @provider.stubs(:get_account_transactions).with(account_id: "bank-1").returns(banking_txns_payload)
    @provider.stubs(:get_account_transactions).with(account_id: "inv-1").returns([])
    PluggyItem.any_instance.stubs(:pluggy_provider).returns(@provider)

    # Finalization + phase-4 balance recompute are covered by unit tests; keep this
    # isolated to the data-landing chain (Importer → Processor → adapter).
    PluggyItem.any_instance.stubs(:perform_post_sync)
    PluggyItem.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.stubs(:broadcast_sync_complete)
    PluggyItem.any_instance.stubs(:schedule_account_syncs)
  end

  test "sync lands banking transaction and investment holding end to end" do
    sign_in @user

    linked_before = PluggyAccount.where(pluggy_item: @pluggy_item).count

    sync = @pluggy_item.syncs.create!
    sync.perform

    @pluggy_item.reload

    # Clean run → item recovered; the two snapshot accounts persist (finds in place).
    assert_equal "good", @pluggy_item.status
    assert_equal linked_before, PluggyAccount.where(pluggy_item: @pluggy_item).count

    # Banking → real Transaction entry landed on depository. Pluggy's -42.0 expense
    # is negated by parse_transaction_amount to Sure's +42.0 (money-out positive).
    entry = @depository.entries.find_by(external_id: "tx-1", source: "pluggy")
    assert_not_nil entry, "banking transaction entry tx-1 should land on depository"
    assert_kind_of Transaction, entry.entryable
    assert_in_delta 42.0, entry.amount.to_f, 0.001
    assert_equal "BRL", entry.currency

    # Investment → real Holding landed on investment account for PETR4 (resolve_security
    # creates the Security row since PETR4 isn't a fixture).
    holding = @investment.holdings.joins(:security).find_by(securities: { ticker: "PETR4" })
    assert_not_nil holding, "PETR4 holding should land on investment account"
    assert_equal @investment.id, holding.account_id
    assert_in_delta 100.0, holding.qty.to_f, 0.001
    assert_in_delta 35.5, holding.price.to_f, 0.001
    assert_equal "BRL", holding.currency
  end

  private

    def investments_payload
      # id drives get_investment_transactions lookup; the Importer snapshots this
      # whole array as the investment account's raw_holdings_payload.
      [ {
        "id" => "inv-1",
        "code" => "PETR4",
        "name" => "Petrobras PN",
        "quantity" => 100,
        "price" => 35.5,
        "currencyCode" => "BRL"
      } ]
    end

    def accounts_payload
      [
        { "id" => "bank-1", "type" => "credit", "name" => "Checking", "balance" => 1000.0, "currencyCode" => "BRL" },
        { "id" => "inv-1", "type" => "investment", "name" => "Brokerage", "balance" => 5000.0, "currencyCode" => "BRL" }
      ]
    end

    def banking_txns_payload
      [
        {
          "id" => "tx-1",
          "amount" => -42.0,
          "status" => "POSTED",
          "date" => "2026-07-01",
          "currencyCode" => "BRL",
          "description" => "Groceries"
        }
      ]
    end
end
