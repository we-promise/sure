require "test_helper"

class DirectaItem::PortfolioNormalizerTest < ActiveSupport::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    @item = connected_item
  end

  test "normalizes a complete cash-only snapshot and preserves signed owned liquidity" do
    snapshot = provider_snapshot(cash_amount: BigDecimal("-12.34"))

    normalized = DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)

    assert_equal "EUR", normalized.currency
    assert_equal BigDecimal("-12.34"), normalized.cash_balance
    assert_equal BigDecimal("-12.34"), normalized.current_balance
    assert_empty normalized.positions
    assert_nil normalized.raw_position_metadata
  end

  test "rejects a snapshot without both cash and positions completion markers" do
    snapshot = provider_snapshot(positions_complete: false)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)
    end

    assert_equal "partial_snapshot", error.code
  end

  test "rejects unknown stream messages even when the known fields are complete" do
    snapshot = provider_snapshot(unknown_message_types: [ "88" ])

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)
    end

    assert_equal "partial_snapshot", error.code
  end

  test "rejects snapshots from another identity or session generation" do
    snapshot = provider_snapshot(account_identity: "99999", connection_generation: 4)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)
    end

    assert_equal "account_identity_changed", error.code
  end

  test "does not treat an unpriced position average cost as market value" do
    position = Provider::Directa::Position.new(
      univoco: "position-1",
      quantity: 2,
      raw_quantity: "2",
      raw_average_price: "50",
      raw_fields: []
    )
    snapshot = provider_snapshot(positions: [ position ])

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)
    end

    assert_equal "awaiting_valuation", error.code
  end

  test "rejects duplicate position identities before aggregation" do
    positions = [
      position(univoco: "lot-1"),
      position(univoco: "lot-1")
    ]

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::PortfolioNormalizer.new(@item).normalize(provider_snapshot(positions: positions))
    end

    assert_equal "duplicate_position", error.code
  end

  test "rejects a receive timestamp outside the current sync window" do
    snapshot = provider_snapshot(observed_at: 2.days.ago)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::PortfolioNormalizer.new(@item).normalize(snapshot)
    end

    assert_equal "invalid_snapshot", error.code
  end

  private

    def connected_item
      DirectaItem.create!(
        family: families(:dylan_family),
        owner: users(:family_admin),
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

    def position(univoco:)
      Provider::Directa::Position.new(
        univoco: univoco,
        quantity: 1,
        raw_quantity: "1",
        raw_average_price: "50",
        raw_fields: []
      )
    end
end
