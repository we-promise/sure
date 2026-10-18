require "test_helper"

class DirectaAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item = DirectaItem.create!(
      family: families(:dylan_family),
      owner: users(:family_admin),
      broker_account: "00123",
      account_identity: "00123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      connection_generation: 1,
      status: :connected
    )
    DirectaItem::Importer.new(@item).import(snapshot: cash_snapshot)
    @provider_account = @item.directa_accounts.sole
  end

  test "preserves normalized exact quantities in offline ISIN holdings without inventing basis" do
    normalized = normalized_snapshot(
      date: Date.current,
      positions: [ normalized_position(quantity: BigDecimal("1.25"), amount: BigDecimal("250")) ]
    )

    DirectaAccount::HoldingsProcessor.new(@provider_account).process(normalized)

    holding = @provider_account.account.holdings.sole
    assert_equal BigDecimal("1.25"), holding.qty
    assert_equal BigDecimal("200"), holding.price
    assert_equal BigDecimal("250"), holding.amount
    assert_nil holding.cost_basis
    assert_equal "US0378331005", holding.security.ticker
    assert_equal "XNAS", holding.security.exchange_operating_mic
    assert holding.security.offline?
    assert_equal "directa_isin", holding.security.offline_reason
    assert_equal holding.security.id, holding.provider_security_id
    assert_equal "directa", holding.account_provider.provider_name
  end

  test "a complete empty normalized snapshot tombstones only Directa holdings" do
    first_snapshot = normalized_snapshot(
      date: Date.current,
      positions: [ normalized_position(quantity: BigDecimal("2"), amount: BigDecimal("200")) ]
    )
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(first_snapshot)

    next_snapshot = normalized_snapshot(date: Date.current + 1.day, positions: [])
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(next_snapshot)

    assert_equal [ BigDecimal("2"), BigDecimal("0") ], @provider_account.account.holdings.order(:date).pluck(:qty)
    assert_empty @provider_account.account.current_holdings
  end

  test "fails closed when a manual holding occupies the normalized provider identity" do
    normalized_position = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"))
    security = Security.create!(
      ticker: normalized_position.isin,
      exchange_operating_mic: normalized_position.mic,
      name: normalized_position.name,
      offline: true,
      offline_reason: "manual"
    )
    @provider_account.account.holdings.create!(
      security: security,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "EUR",
      date: Date.current
    )

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaAccount::HoldingsProcessor.new(@provider_account).process(
        normalized_snapshot(date: Date.current, positions: [ normalized_position ])
      )
    end

    assert_equal "holding_conflict", error.code
    assert_nil @provider_account.account.holdings.sole.account_provider_id
  end

  private

    def cash_snapshot
      Provider::Directa::Snapshot.new(
        account_number: "00123",
        account_identity: "00123",
        connection_generation: 1,
        observed_at: Time.current,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: true,
        cash: Provider::Directa::Cash.new(
          amount: BigDecimal("100"),
          raw_amount: "100",
          equity_availability: nil,
          equity_margin_availability: nil,
          realtime_availability: nil,
          consolidated_performance: nil,
          raw_fields: [],
          field_sources: Provider::Directa::FIELD_SOURCES
        ),
        positions: [],
        unknown_message_types: []
      )
    end

    def normalized_snapshot(date:, positions: [])
      DirectaItem::PortfolioNormalizer::Snapshot.new(
        account_identity: "00123",
        account_number: "00123",
        connection_generation: 1,
        observed_at: date.in_time_zone,
        date: date,
        currency: "EUR",
        cash_balance: BigDecimal("100"),
        current_balance: BigDecimal("100") + positions.sum(BigDecimal("0"), &:market_value),
        positions: positions,
        raw_position_metadata: positions.map(&:metadata)
      )
    end

    def normalized_position(quantity:, amount:)
      DirectaItem::PortfolioNormalizer::Position.new(
        isin: "US0378331005",
        mic: "XNAS",
        name: "Apple Inc.",
        quantity: quantity,
        market_value: amount,
        price: amount / quantity,
        external_id: "directa-position-US0378331005-XNAS-#{Date.current.iso8601}",
        metadata: [ { "univoco" => "synthetic-position" } ]
      )
    end
end
