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
      assert_equal [ BigDecimal("45"), BigDecimal("45"), BigDecimal("45") ], calculator.projected_rows.map(&:cost_basis)

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
    assert_equal [ BigDecimal("45"), BigDecimal("45"), BigDecimal("45") ], projected.map(&:cost_basis)
    assert_equal [ "provider", "provider", "provider" ], projected.map(&:cost_basis_source)
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
          market_value: BigDecimal("120"),
          cost_basis: BigDecimal("55")
        )
      )
    end

    refreshed = @account.holdings.find_by!(security: security, date: next_date)
    assert_equal BigDecimal("120"), refreshed.amount
    assert_equal BigDecimal("60"), refreshed.price
    assert_equal BigDecimal("2"), refreshed.qty
    assert_equal BigDecimal("55"), refreshed.cost_basis
    assert_equal "provider", refreshed.cost_basis_source
    assert_equal @item.directa_account.account_provider.id, refreshed.account_provider_id
    assert_equal "directa-position-US0378331005-XNAS-#{next_date.iso8601}", refreshed.external_id
    assert_equal 3, @account.holdings.where(security: security).count
    assert_equal BigDecimal("150"), @account.reload.balance
    assert_equal BigDecimal("30"), @account.cash_balance
    assert_equal BigDecimal("150"), @item.directa_account.reload.current_balance
    assert DirectaAccount::ContentValidator.new(@item.directa_account).validate!
  end

  test "clears stale basis from generated Directa projections when the broker basis becomes unknown" do
    first_date = Date.current - 2.days
    first_observation = first_date.in_time_zone + 12.hours

    travel_to(first_observation) do
      @account = DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(observed_at: first_observation, cash_amount: BigDecimal("25"), market_value: BigDecimal("100"))
      ).account
    end

    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_sync_complete)

    travel_to(Date.current.in_time_zone + 12.hours) do
      Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings
    end

    projections = @account.holdings.where(account_provider_id: nil).order(:date).to_a
    assert_equal [ BigDecimal("45"), BigDecimal("45") ], projections.map(&:cost_basis)
    assert_equal [ "provider", "provider" ], projections.map(&:cost_basis_source)
    projections.first.set_manual_cost_basis!(0)

    provider_holding = @account.holdings.find_by!(account_provider_id: @item.directa_account.account_provider.id)
    provider_holding.update!(cost_basis: nil, cost_basis_source: nil)

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    cleared = @account.holdings.where(account_provider_id: nil).order(:date).to_a
    assert_equal [ BigDecimal("0"), BigDecimal("0") ], cleared.map(&:cost_basis)
    assert_equal [ "manual", "manual" ], cleared.map(&:cost_basis_source)
    assert_equal [ true, true ], cleared.map(&:cost_basis_locked?)
  end

  test "carries a positive manual basis through gap days without changing its provenance" do
    first_date = Date.current - 1.day
    first_observation = first_date.in_time_zone + 12.hours

    travel_to(first_observation) do
      @account = DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(observed_at: first_observation, cash_amount: BigDecimal("25"), market_value: BigDecimal("100"))
      ).account
    end

    provider_holding = @account.holdings.sole
    provider_holding.set_manual_cost_basis!(BigDecimal("42"))

    projected = Holding::DirectaSnapshotCalculator.new(
      @account,
      account_provider_id: @item.directa_account.account_provider.id
    ).projected_rows

    assert_equal [ first_date, first_date.next_day ], projected.map(&:date)
    assert_equal [ BigDecimal("42"), BigDecimal("42") ], projected.map(&:cost_basis)
    assert_equal [ "manual", "manual" ], projected.map(&:cost_basis_source)
    assert_equal [ true, true ], projected.map(&:cost_basis_locked)
  end

  test "materializes a locked manual basis beside a regular provider basis in one batch" do
    first_date = Date.current - 1.day
    first_observation = first_date.in_time_zone + 12.hours

    travel_to(first_observation) do
      second_position = provider_position(
        market_value: BigDecimal("60"),
        cost_basis: BigDecimal("30"),
        isin: "US5949181045",
        univoco: "synthetic-position-2",
        description: "Synthetic second listed equity"
      )
      @account = DirectaItem::Importer.new(@item).import(
        snapshot: provider_snapshot(
          observed_at: first_observation,
          cash_amount: BigDecimal("25"),
          market_value: BigDecimal("100"),
          additional_positions: [ second_position ]
        )
      ).account
    end

    provider_rows = @account.holdings.where(account_provider_id: @item.directa_account.account_provider.id).order(:amount).to_a
    assert_equal 2, provider_rows.size
    provider_rows.first.set_manual_cost_basis!(BigDecimal("42"))

    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_sync_complete)
    travel_to(Date.current.in_time_zone + 12.hours) do
      Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings
    end

    projected_rows = @account.holdings
      .where(account_provider_id: nil, date: Date.current)
      .order(:amount)
      .to_a
    assert_equal [ BigDecimal("42"), BigDecimal("45") ], projected_rows.map(&:cost_basis)
    assert_equal [ "manual", "provider" ], projected_rows.map(&:cost_basis_source)
    assert_equal [ true, false ], projected_rows.map(&:cost_basis_locked?)
  end

  private

    def provider_snapshot(observed_at:, cash_amount:, market_value:, cost_basis: BigDecimal("45"), additional_positions: [])
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
        positions: [ provider_position(market_value: market_value, cost_basis: cost_basis) ] + additional_positions,
        unknown_message_types: []
      )
    end

    def provider_position(market_value:, cost_basis:, isin: "US0378331005", univoco: "synthetic-position", description: "Synthetic listed fund")
      metadata = Provider::Directa::InstrumentMetadata.new(
        requested_code: "SYNTHETIC",
        canonical_code: "SYNTHETIC",
        isin: isin,
        currency: "EUR",
        description: description,
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
        univoco: univoco,
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
        valuation_source: "synthetic_verified_snapshot",
        cost_basis: cost_basis
      )
    end
end
