require "test_helper"

class DirectaItem::SyncerTest < ActiveSupport::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @item = DirectaItem.create!(
      family: @family,
      owner: users(:family_admin),
      broker_account: "00123",
      account_identity: "00123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      connection_generation: 3,
      status: :connected
    )
  end

  test "imports a complete cash-only snapshot through the persisted item provider" do
    client = mock("Directa reader")
    client.expects(:fetch_portfolio_snapshot).returns(provider_snapshot(cash_amount: BigDecimal("35")))
    @item.stubs(:provider).returns(client)
    DirectaHistorySyncJob.expects(:perform_later).with(@item.id).returns(stub)
    sync = Sync.create!(syncable: @item)

    result = DirectaItem::Syncer.new(@item).perform_sync(sync)

    assert_instance_of DirectaItem::Importer::Result, result
    assert_equal BigDecimal("35"), @item.accounts.sole.reload.balance
    assert_equal BigDecimal("35"), @item.accounts.sole.cash_balance
    assert_nil @item.reload.last_sync_error_code
  end

  test "keeps the old account and session when Directa authentication expires" do
    account = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(cash_amount: BigDecimal("35"))).account
    prior_snapshot_at = @item.reload.portfolio_snapshot_at
    client = mock("Directa reader")
    client.expects(:fetch_portfolio_snapshot).raises(
      Provider::Directa::AuthenticationError.new("private response", failure_code: :authentication_failed)
    )
    @item.stubs(:provider).returns(client)
    DirectaHistorySyncJob.expects(:perform_later).never
    sync = Sync.create!(syncable: @item)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Syncer.new(@item).perform_sync(sync)
    end

    assert_equal "sync_failed", error.code
    assert @item.reload.requires_update?
    assert_equal "synthetic-multi-token", @item.multi_token
    assert_equal "synthetic-mono-token", @item.mono_token
    assert_equal BigDecimal("35"), account.reload.balance
    assert_equal BigDecimal("35"), account.cash_balance
    assert_equal prior_snapshot_at, @item.portfolio_snapshot_at
    assert_equal "sync_failed", @item.last_sync_error_code
    refute_includes error.message, "private response"
  end

  test "rejects a result after a disconnect generation changes while the provider request is in flight" do
    captured = provider_snapshot(cash_amount: BigDecimal("99"))
    client = Object.new
    item = @item
    client.define_singleton_method(:fetch_portfolio_snapshot) do
      item.update!(connection_generation: 4, status: :requires_update)
      captured
    end
    @item.stubs(:provider).returns(client)
    sync = Sync.create!(syncable: @item)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Syncer.new(@item).perform_sync(sync)
    end

    assert_equal "account_identity_changed", error.code
    assert_empty @item.directa_accounts
    assert_equal 4, @item.reload.connection_generation
    assert_nil @item.last_sync_error_code
  end

  test "does not contact Directa when encryption or connection status is unavailable" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    @item.expects(:provider).never
    sync = Sync.create!(syncable: @item)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Syncer.new(@item).perform_sync(sync)
    end

    assert_equal "sync_failed", error.code
    assert_empty @item.directa_accounts
  end

  test "a history enqueue failure preserves a successful portfolio import" do
    client = mock("Directa reader")
    client.expects(:fetch_portfolio_snapshot).returns(provider_snapshot(cash_amount: BigDecimal("47")))
    @item.stubs(:provider).returns(client)
    DirectaHistorySyncJob.expects(:perform_later).with(@item.id).raises(StandardError, "private queue detail")
    sync = Sync.create!(syncable: @item)

    result = DirectaItem::Syncer.new(@item).perform_sync(sync)

    assert_instance_of DirectaItem::Importer::Result, result
    assert_equal BigDecimal("47"), @item.accounts.sole.reload.balance
    assert_equal "history_sync_failed", @item.reload.history_sync_error_code
    refute_includes @item.last_history_sync_error, "private queue detail"
  end

  private

    def provider_snapshot(cash_amount: BigDecimal("100"), positions: [], observed_at: Time.current,
      account_identity: "00123", account_number: "00123", connection_generation: 3)
      Provider::Directa::Snapshot.new(
        account_number: account_number,
        account_identity: account_identity,
        connection_generation: connection_generation,
        observed_at: observed_at,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: true,
        cash: Provider::Directa::Cash.new(
          amount: cash_amount,
          raw_amount: cash_amount.to_s,
          equity_availability: nil,
          equity_margin_availability: nil,
          realtime_availability: nil,
          consolidated_performance: nil,
          raw_fields: [],
          field_sources: Provider::Directa::FIELD_SOURCES
        ),
        positions: positions,
        unknown_message_types: []
      )
    end
end
