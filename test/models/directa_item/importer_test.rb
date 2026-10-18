require "test_helper"

class DirectaItem::ImporterTest < ActiveSupport::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @before_account_ids = @family.accounts.ids
    @item = connected_item
  end

  test "imports owned cash once into one linked Investment account" do
    result = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(cash_amount: BigDecimal("125.50")))

    account = result.account
    assert account.investment?
    assert_equal "brokerage", account.subtype
    assert_equal @family.id, account.family_id
    assert_equal @owner.id, account.owner_id
    assert_equal "EUR", account.currency
    assert_equal BigDecimal("125.50"), account.balance
    assert_equal BigDecimal("125.50"), account.cash_balance
    assert_equal 1, @item.directa_accounts.count
    assert_equal 1, @item.accounts.count
    assert_equal "DirectaAccount", account.account_providers.sole.provider_type
    assert_empty account.holdings
    assert_equal BigDecimal("125.50"), @item.directa_accounts.sole.current_balance
  end

  test "refreshes the same-day cash anchor idempotently" do
    captured_at = Time.current
    @item.directa_accounts # ensure association is cold before first import
    first = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(cash_amount: BigDecimal("100"), observed_at: captured_at))
    account = first.account
    anchor_count = account.valuations.current_anchor.count

    DirectaItem::Importer.new(@item).import(
      snapshot: provider_snapshot(cash_amount: BigDecimal("110"), observed_at: captured_at + 1.minute)
    )

    assert_equal 1, @item.accounts.count
    assert_equal 1, account.valuations.current_anchor.count
    assert_equal BigDecimal("110"), account.reload.balance
    assert_equal BigDecimal("110"), account.cash_balance
    assert_equal captured_at.to_date, account.current_anchor_date
  end

  test "accepts successive daily provider anchors after the prior anchor rotates to reconciliation" do
    account = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot).account
    first_anchor = account.valuations.current_anchor.sole
    next_date = Date.current + 1.day

    travel_to(next_date.in_time_zone + 12.hours) do
      DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot).account
    end

    assert first_anchor.reload.reconciliation?
    assert_equal 1, account.valuations.current_anchor.count
    assert_equal next_date, account.current_anchor_date
  end

  test "accepts a negative owned cash balance without interpreting buying power" do
    account = DirectaItem::Importer.new(@item).import(
      snapshot: provider_snapshot(cash_amount: BigDecimal("-25.75"))
    ).account

    assert_equal BigDecimal("-25.75"), account.reload.balance
    assert_equal BigDecimal("-25.75"), account.cash_balance
    assert_equal BigDecimal("-25.75"), @item.directa_accounts.sole.cash_balance
  end

  test "keeps the prior account and snapshot when a later stream is incomplete" do
    first = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(cash_amount: BigDecimal("100")))
    account = first.account
    prior_snapshot = @item.reload.portfolio_snapshot_at
    prior_anchor = account.valuations.current_anchor.sole.entry.amount
    later = provider_snapshot(cash_amount: BigDecimal("200"), observed_at: Time.current + 1.minute, positions_complete: false)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Importer.new(@item).import(snapshot: later)
    end

    assert_equal "partial_snapshot", error.code
    assert_equal prior_snapshot, @item.reload.portfolio_snapshot_at
    assert_equal "partial_snapshot", @item.last_sync_error_code
    assert_equal prior_anchor, account.valuations.current_anchor.sole.entry.amount
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal BigDecimal("100"), @item.directa_accounts.sole.cash_balance
  end

  test "does not bootstrap native accounts while valuation is unresolved" do
    source_position = Provider::Directa::Position.new(
      univoco: "position-1",
      quantity: 1,
      raw_quantity: "1",
      raw_average_price: "100",
      raw_fields: []
    )

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(positions: [ source_position ]))
    end

    assert_equal "awaiting_valuation", error.code
    assert_equal @before_account_ids, @family.accounts.ids
    assert_empty @item.directa_accounts
    assert_equal "awaiting_valuation", @item.last_sync_error_code
  end

  test "keeps the Directa snapshot unchanged when unrelated manual holdings exist" do
    account = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(cash_amount: BigDecimal("100"))).account
    snapshot_at = @item.reload.portfolio_snapshot_at
    security = Security.create!(
      ticker: "CUSTOM:MANUAL",
      name: "Manual holding",
      exchange_operating_mic: "XNAS",
      offline: true,
      offline_reason: "manual"
    )
    manual_holding = account.holdings.create!(
      security: security,
      qty: 1,
      price: 10,
      amount: 10,
      currency: "EUR",
      date: Date.current
    )

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(cash_amount: BigDecimal("200"), observed_at: Time.current + 1.minute)
      )
    end

    assert_equal "holding_conflict", error.code
    assert_equal snapshot_at, @item.reload.portfolio_snapshot_at
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal BigDecimal("100"), @item.directa_accounts.sole.current_balance
    assert_equal manual_holding.id, account.holdings.sole.id
    assert_nil account.holdings.sole.account_provider_id
  end

  test "does not apply a snapshot from a previous connection generation" do
    DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(cash_amount: BigDecimal("100")))
    account = @item.accounts.sole
    prior_snapshot = @item.reload.portfolio_snapshot_at
    @item.update!(connection_generation: 4)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(cash_amount: BigDecimal("999"), observed_at: Time.current + 1.minute)
      )
    end

    assert_equal "account_identity_changed", error.code
    assert_equal prior_snapshot, @item.reload.portfolio_snapshot_at
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal BigDecimal("100"), account.cash_balance
  end

  test "rejects older observations and future account anchors without changing the snapshot" do
    first_at = Time.current
    account = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot(observed_at: first_at)).account
    @item.update!(portfolio_snapshot_at: first_at + 10.minutes)
    prior_balance = account.reload.balance

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(cash_amount: BigDecimal("999"), observed_at: first_at + 1.minute)
      )
    end

    assert_equal "stale_snapshot", error.code
    assert_equal BigDecimal("100"), prior_balance
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal (first_at + 10.minutes).to_i, @item.reload.portfolio_snapshot_at.to_i
  end

  private

    def connected_item
      DirectaItem.create!(
        family: @family,
        owner: @owner,
        broker_account: "00123",
        account_identity: "00123",
        multi_token: "synthetic-multi-token",
        mono_token: "synthetic-mono-token",
        connection_generation: 3,
        status: :connected
      )
    end

    def provider_snapshot(cash_amount: BigDecimal("100"), positions: [], observed_at: Time.current,
      account_identity: "00123", account_number: "00123", connection_generation: 3,
      cash_seen: true, positions_complete: true, unknown_message_types: [])
      Provider::Directa::Snapshot.new(
        account_number: account_number,
        account_identity: account_identity,
        connection_generation: connection_generation,
        observed_at: observed_at,
        cash_seen: cash_seen,
        positions_complete: positions_complete,
        full_photo_complete: true,
        cash: provider_cash(cash_amount),
        positions: positions,
        unknown_message_types: unknown_message_types
      )
    end

    def provider_cash(amount)
      Provider::Directa::Cash.new(
        amount: amount,
        raw_amount: amount&.to_s,
        equity_availability: nil,
        equity_margin_availability: nil,
        realtime_availability: nil,
        consolidated_performance: nil,
        raw_fields: [],
        field_sources: Provider::Directa::FIELD_SOURCES
      )
    end
end
