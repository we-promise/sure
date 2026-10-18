require "test_helper"

class Holding::DirectaSnapshotCalculatorTest < ActiveSupport::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @item = DirectaItem.create!(
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

  test "materializes only Directa snapshot values from the first observed date and adopts the projection on reimport" do
    today = Date.current
    first_date = today - 2.days
    next_date = today
    first_observation = first_date.in_time_zone + 12.hours

    travel_to(first_observation) do
      @account = DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(observed_at: first_observation, cash_amount: BigDecimal("25"), market_value: BigDecimal("100"))
      ).account
    end

    security = @account.holdings.sole.security
    Security::Price.create!(security: security, date: first_date + 1.day, price: "999", currency: "USD")
    Security::Price.create!(security: security, date: next_date, price: "777", currency: "EUR")
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.unstub(:sync_later)

    travel_to(next_date.in_time_zone + 12.hours) do
      calculator = Holding::DirectaSnapshotCalculator.new(
        @account,
        account_provider_id: @item.directa_account.account_provider.id
      )
      assert_equal [ first_date, first_date + 1.day, next_date ], calculator.projected_rows.map(&:date)

      @account.sync_later
      sync = @account.syncs.visible.sole
      sync.perform
      assert sync.reload.completed?, sync.error
    end

    projected = @account.holdings.where(security: security).order(:date).to_a
    assert_equal [ first_date, first_date + 1.day, next_date ], projected.map(&:date)
    assert_equal [ BigDecimal("100"), BigDecimal("100"), BigDecimal("100") ], projected.map(&:amount)
    assert_equal [ BigDecimal("50"), BigDecimal("50"), BigDecimal("50") ], projected.map(&:price)
    assert_equal [ BigDecimal("2"), BigDecimal("2"), BigDecimal("2") ], projected.map(&:qty)
    assert_equal @item.directa_account.account_provider.id, projected.first.account_provider_id
    assert projected.drop(1).all? { |holding| holding.account_provider_id.nil? && holding.external_id.blank? }
    assert_empty @account.holdings.where("date < ?", first_date)
    assert_equal BigDecimal("125"), @account.reload.balance
    assert_equal BigDecimal("25"), @account.cash_balance
    assert_equal BigDecimal("125"), @item.directa_account.reload.current_balance

    updated_observation = next_date.in_time_zone + 12.hours + 1.minute
    Account.any_instance.stubs(:sync_later).returns(nil)
    travel_to(updated_observation) do
      DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(
          observed_at: updated_observation,
          cash_amount: BigDecimal("30"),
          market_value: BigDecimal("120")
        )
      )
    end

    refreshed = @account.holdings.find_by!(security: security, date: next_date)
    assert_equal BigDecimal("120"), refreshed.amount
    assert_equal BigDecimal("60"), refreshed.price
    assert_equal BigDecimal("2"), refreshed.qty
    assert_equal @item.directa_account.account_provider.id, refreshed.account_provider_id
    assert_equal "directa-position-US0378331005-XNAS-#{next_date.iso8601}", refreshed.external_id
    assert_equal 3, @account.holdings.where(security: security).count
    assert_equal BigDecimal("150"), @account.reload.balance
    assert_equal BigDecimal("30"), @account.cash_balance
    assert_equal BigDecimal("150"), @item.directa_account.reload.current_balance
    assert DirectaAccount::ContentValidator.new(@item.directa_account).validate!
  end

  private

    def provider_snapshot(observed_at:, cash_amount:, market_value:)
      Provider::Directa::Snapshot.new(
        account_number: "00123",
        account_identity: "00123",
        connection_generation: 3,
        observed_at: observed_at,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: true,
        cash: Provider::Directa::Cash.new(
          amount: cash_amount,
          raw_amount: cash_amount.to_s("F"),
          equity_availability: nil,
          equity_margin_availability: nil,
          realtime_availability: nil,
          consolidated_performance: nil,
          raw_fields: [],
          field_sources: Provider::Directa::FIELD_SOURCES
        ),
        positions: [ provider_position(market_value: market_value) ],
        unknown_message_types: []
      )
    end

    def provider_position(market_value:)
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
      Provider::Directa::Position.new(
        univoco: "synthetic-position",
        quantity: BigDecimal("2"),
        raw_quantity: "2",
        raw_average_price: "45",
        raw_fields: [],
        instrument_metadata: metadata,
        valuation_status: :verified,
        valuation_date: Time.current.to_date,
        valuation_currency: "EUR",
        current_price: market_value / 2,
        market_value: market_value,
        valuation_source: "synthetic_verified_snapshot"
      )
    end
end
