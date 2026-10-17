require "test_helper"

class FinecoItem::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.reset
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    @family = families(:dylan_family)
    @item = FinecoItem.new(
      family: @family,
      owner: users(:family_admin),
      gsessionid: "synthetic-session",
      account_index: "2",
      dossier_index: "11",
      bank_account_number: "SYNTHETIC-ACCOUNT",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
      captured_at: Time.current
    )
  end

  teardown { Current.reset }

  test "closed identity capability stops sync before a bank request or snapshot import" do
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item.import_portfolio_snapshot!(payload: portfolio_payload, captured_at: Time.current)
    account = @item.accounts.sole
    holding_before = account.holdings.sole.attributes
    balance_before = account.reload.balance
    Provider::Fineco.stubs(:verified_identity_contract?).returns(false)
    Provider::Fineco.expects(:new).never
    FinecoItem::Importer.expects(:new).never
    Account.any_instance.expects(:sync_later).never
    sync = Sync.create!(syncable: @item)

    sync.perform

    assert sync.reload.failed?
    assert_equal "identity_verification_required", @item.reload.last_sync_error_code
    assert_equal holding_before, account.holdings.sole.attributes
    assert_equal balance_before, account.reload.balance
    assert_empty account.syncs
  end

  test "full Sync lifecycle waits for the child account materialization and propagates its window" do
    captured_at = Time.current
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item.import_portfolio_snapshot!(payload: portfolio_payload, captured_at: captured_at)
    account = @item.accounts.sole
    Account.any_instance.unstub(:sync_later)

    parent = Sync.create!(
      syncable: @item,
      window_start_date: Date.current - 2.days,
      window_end_date: Date.current
    )
    result = Provider::Fineco::PortfolioResult.new(
      payload: portfolio_payload,
      rotated_gsessionid: nil,
      account_number: "SYNTHETIC-ACCOUNT",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier")
    )
    Provider::Fineco.any_instance.stubs(:fetch_portfolio_summary).returns(result)
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.stubs(:broadcast_refresh)

    assert_enqueued_jobs 1, only: SyncJob do
      parent.perform
    end

    child = account.syncs.sole
    assert_equal parent.id, child.parent_id
    assert_equal parent.window_start_date, child.window_start_date
    assert_equal parent.window_end_date, child.window_end_date
    assert parent.syncing?
    assert child.pending?

    child.perform

    assert child.reload.completed?
    assert parent.reload.completed?
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal BigDecimal("0"), account.cash_balance
    assert_equal BigDecimal("2"), account.current_holdings.sole.qty
  end

  test "authentication expiry clears the session and prevents automatic rescheduling" do
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item.import_portfolio_snapshot!(payload: portfolio_payload, captured_at: Time.current)
    @item.accounts.sole
    Account.any_instance.unstub(:sync_later)
    sync = Sync.create!(syncable: @item)
    Provider::Fineco.any_instance.stubs(:fetch_portfolio_summary)
      .raises(Provider::Fineco::ReauthenticationRequired, "private bank message")

    sync.perform

    assert sync.reload.failed?
    assert @item.reload.requires_update?
    assert_nil @item.gsessionid
    assert_equal "reauthentication_required", @item.last_sync_error_code
    assert_not @item.syncable?
    assert_not FinecoItem.syncable.exists?(id: @item.id)
    refute_includes sync.error, "private bank message"
  end

  test "a queued sync rechecks that its owner is active before contacting Fineco" do
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item.import_portfolio_snapshot!(payload: portfolio_payload, captured_at: Time.current)
    @item.accounts.sole
    Account.any_instance.unstub(:sync_later)
    @item.owner.update_column(:active, false)
    sync = Sync.create!(syncable: @item)
    Provider::Fineco.any_instance.expects(:fetch_portfolio_summary).never

    sync.perform

    assert sync.reload.failed?
    assert @item.reload.requires_update?
    assert_nil @item.gsessionid
    assert_not @item.syncable?
  end

  private

    def portfolio_payload
      position = {
        "instrId" => "US0000000002",
        "venueSystem" => "XETRA",
        "symbol" => "SYNTH",
        "description" => "Synthetic fund",
        "type" => "etf",
        "currencyCd" => "EUR",
        "qty" => "2",
        "avgPrice" => "45",
        "marketPrice" => "50",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "accrual" => "0.5"
      }
      summary = {
        "currencyCd" => "EUR",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "profitLossPerc" => "11.11",
        "accrual" => "0.5"
      }

      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => [ "EUR" ], "show" => [ "EUR" ] },
          "instrumentTypes" => { "total" => [ "etf" ], "show" => [ "etf" ] }
        },
        "positions" => { "show" => [ position ] },
        "summary" => { "show" => summary, "total" => summary }
      }
    end
end
