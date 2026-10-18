require "test_helper"

class DirectaAccount::ContentValidatorTest < ActiveSupport::TestCase
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

  test "rejects locked manual holdings and foreign-provider holdings" do
    first_date = Date.current - 1.day
    first_observation = first_date.in_time_zone.end_of_day - 10.minutes
    next_observation = first_date.next_day.in_time_zone.beginning_of_day + 20.minutes

    travel_to(first_observation) do
      @account = DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(observed_at: first_observation)
      ).account
    end

    security = @account.holdings.sole.security
    manual_holding = @account.holdings.create!(
      security: security,
      qty: 2,
      price: 50,
      amount: 100,
      currency: "EUR",
      date: first_date.next_day,
      security_locked: true
    )
    validator = DirectaAccount::ContentValidator.new(@item.directa_account)

    travel_to(next_observation) do
      assert_not validator.generated_snapshot_holding?(manual_holding)
      error = assert_raises(DirectaItem::PortfolioNormalizer::Error) { validator.validate! }
      assert_equal "holding_conflict", error.code
      assert_not @item.directa_account.content_compatible_for_import?
      materialization_error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
        Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings
      end
      assert_equal "holding_conflict", materialization_error.code
      assert_equal BigDecimal("100"), manual_holding.reload.amount
    end

    manual_holding.destroy!
    foreign_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "synthetic-key")
    foreign_account = foreign_item.coinstats_accounts.create!(name: "Other brokerage", currency: "EUR")
    foreign_link = AccountProvider.create!(account: @account, provider: foreign_account)
    foreign_security = Security.create!(ticker: "FOREIGN-HOLDING", name: "Foreign holding")
    @account.holdings.create!(
      security: foreign_security,
      qty: 1,
      price: 10,
      amount: 10,
      currency: "EUR",
      date: first_date.next_day,
      account_provider: foreign_link
    )

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) { validator.validate! }
    assert_equal "holding_conflict", error.code
  end

  private

    def provider_snapshot(observed_at:)
      metadata = Provider::Directa::InstrumentMetadata.new(
        requested_code: "SYNTHETIC",
        canonical_code: "SYNTHETIC",
        isin: "US0378331005",
        currency: "EUR",
        description: "Synthetic listed fund",
        directa_market: "NASDAQ",
        directa_segment: "equity",
        multiplier: BigDecimal("1"),
        raw_multiplier: "1",
        price_codes: [],
        tick_table: nil,
        tick_size: nil,
        raw_tick_size: nil,
        identity_status: :verified,
        field_sources: Provider::Directa::FIELD_SOURCES,
        mic: "XNAS"
      )
      position = Provider::Directa::Position.new(
        univoco: "synthetic-position",
        quantity: BigDecimal("2"),
        raw_quantity: "2",
        raw_average_price: "45",
        raw_fields: [],
        instrument_metadata: metadata,
        valuation_status: :verified,
        valuation_date: observed_at.to_date,
        valuation_currency: "EUR",
        current_price: BigDecimal("50"),
        market_value: BigDecimal("100"),
        valuation_source: "synthetic_verified_snapshot"
      )
      cash = Provider::Directa::Cash.new(
        amount: BigDecimal("25"),
        raw_amount: "25",
        equity_availability: nil,
        equity_margin_availability: nil,
        realtime_availability: nil,
        consolidated_performance: nil,
        raw_fields: [],
        field_sources: Provider::Directa::FIELD_SOURCES
      )

      Provider::Directa::Snapshot.new(
        account_number: "00123",
        account_identity: "00123",
        connection_generation: 3,
        observed_at: observed_at,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: true,
        cash: cash,
        positions: [ position ],
        unknown_message_types: []
      )
    end
end
