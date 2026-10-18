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

  test "imports provider basis per unit without multiplying quantity or market value" do
    normalized = normalized_snapshot(
      date: Date.current,
      positions: [ normalized_position(quantity: BigDecimal("1.25"), amount: BigDecimal("250"), cost_basis: BigDecimal("42.5")) ]
    )

    DirectaAccount::HoldingsProcessor.new(@provider_account).process(normalized)

    holding = @provider_account.account.holdings.sole
    assert_equal BigDecimal("1.25"), holding.qty
    assert_equal BigDecimal("250"), holding.amount
    assert_equal BigDecimal("200"), holding.price
    assert_equal BigDecimal("42.5"), holding.cost_basis
    assert_equal "provider", holding.cost_basis_source
  end

  test "preserves a locked manual basis when Directa refreshes it" do
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"))
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: Date.current, positions: [ first ])
    )
    holding = @provider_account.account.holdings.sole
    holding.set_manual_cost_basis!(BigDecimal("35"))
    provider_security = holding.provider_security
    remapped_security = Security.create!(ticker: "CUSTOM:APPLE", name: "Personal Apple")
    holding.remap_security!(remapped_security)

    refreshed = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("110"), cost_basis: BigDecimal("44"))
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: Date.current, positions: [ refreshed ])
    )

    assert_equal BigDecimal("35"), holding.reload.cost_basis
    assert_equal "manual", holding.cost_basis_source
    assert holding.cost_basis_locked?
    assert holding.security_locked?
    assert_equal remapped_security.id, holding.security_id
    assert_equal provider_security.id, holding.provider_security_id
  end

  test "carries a locked manual basis into a new positive Directa snapshot without materialization" do
    first_date = Date.current - 1.day
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"), date: first_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: first_date, positions: [ first ])
    )
    first_holding = @provider_account.account.holdings.sole
    first_holding.set_manual_cost_basis!(BigDecimal("35"))

    next_date = first_date.next_day
    refreshed = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("110"), cost_basis: BigDecimal("44"), date: next_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: next_date, positions: [ refreshed ])
    )

    next_holding = @provider_account.account.holdings.find_by!(date: next_date)
    assert_equal BigDecimal("35"), next_holding.cost_basis
    assert_equal "manual", next_holding.cost_basis_source
    assert next_holding.cost_basis_locked?
  end

  test "the provider adapter carries remapped security and manual basis into a later snapshot" do
    first_date = Date.current - 1.day
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"), date: first_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: first_date, positions: [ first ])
    )
    first_holding = @provider_account.account.holdings.sole
    first_holding.set_manual_cost_basis!(BigDecimal("35"))
    provider_security = first_holding.provider_security
    remapped_security = Security.create!(ticker: "CUSTOM:APPLE-LATER", name: "Personal Apple")
    first_holding.remap_security!(remapped_security)

    next_date = first_date.next_day
    refreshed = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("110"), cost_basis: BigDecimal("44"), date: next_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: next_date, positions: [ refreshed ])
    )

    next_holding = @provider_account.account.holdings.find_by!(date: next_date)
    assert_equal BigDecimal("35"), next_holding.cost_basis
    assert_equal "manual", next_holding.cost_basis_source
    assert next_holding.cost_basis_locked?
    assert next_holding.security_locked?
    assert_equal remapped_security.id, next_holding.security_id
    assert_equal provider_security.id, next_holding.provider_security_id
  end

  test "carries a locked basis from an exact generated projection into the next provider snapshot" do
    first_date = Date.current - 2.days
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"), date: first_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: first_date, positions: [ first ])
    )
    provider_holding = @provider_account.account.holdings.sole
    provider_security = provider_holding.provider_security
    security = Security.create!(ticker: "CUSTOM:APPLE-PROJECTION", name: "Personal Apple")
    provider_holding.remap_security!(security)
    projected_date = first_date.next_day
    projection = travel_to(projected_date.in_time_zone + 12.hours) do
      Holding::DirectaSnapshotCalculator.new(
        @provider_account.account,
        account_provider_id: @provider_account.account_provider.id
      ).projected_rows.find { |row| row.date == projected_date }
    end
    generated = @provider_account.account.holdings.create!(
      security: security,
      qty: projection.qty,
      price: projection.price,
      amount: projection.amount,
      currency: projection.currency,
      date: projection.date,
      cost_basis: BigDecimal("37"),
      cost_basis_source: "manual",
      cost_basis_locked: true
    )
    assert DirectaAccount::ContentValidator.new(@provider_account).generated_snapshot_holding?(generated)

    next_date = projected_date.next_day
    refreshed = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("120"), cost_basis: BigDecimal("52"), date: next_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: next_date, positions: [ refreshed ])
    )

    next_holding = @provider_account.account.holdings.find_by!(date: next_date)
    assert_equal BigDecimal("37"), next_holding.cost_basis
    assert_equal "manual", next_holding.cost_basis_source
    assert next_holding.cost_basis_locked?
    assert next_holding.security_locked?
    assert_equal security.id, next_holding.security_id
    assert_equal provider_security.id, next_holding.provider_security_id
  end

  test "a zero quantity tombstone resets a locked manual basis before the position reopens" do
    first_date = Date.current - 2.days
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"), date: first_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: first_date, positions: [ first ])
    )
    first_holding = @provider_account.account.holdings.find_by!(date: first_date)
    first_holding.set_manual_cost_basis!(BigDecimal("35"))
    provider_security = first_holding.provider_security
    remapped_security = Security.create!(ticker: "CUSTOM:APPLE-CLOSED", name: "Personal Apple")
    first_holding.remap_security!(remapped_security)

    tombstone_date = first_date.next_day
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: tombstone_date, positions: [])
    )
    tombstone = @provider_account.account.holdings.find_by!(date: tombstone_date)
    assert_equal BigDecimal("0"), tombstone.qty
    assert_nil tombstone.cost_basis
    assert_not tombstone.cost_basis_locked?
    assert_equal remapped_security.id, tombstone.security_id
    assert_equal provider_security.id, tombstone.provider_security_id

    reopen_date = tombstone_date.next_day
    reopened = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("120"), cost_basis: BigDecimal("52"), date: reopen_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: reopen_date, positions: [ reopened ])
    )

    reopened_holding = @provider_account.account.holdings.find_by!(date: reopen_date)
    assert_equal BigDecimal("52"), reopened_holding.cost_basis
    assert_equal "provider", reopened_holding.cost_basis_source
    assert_not reopened_holding.cost_basis_locked?
    assert_equal remapped_security.id, reopened_holding.security_id
    assert_equal provider_security.id, reopened_holding.provider_security_id
  end

  test "same-date reopen after a tombstone uses the new bank basis instead of the prior manual lock" do
    first_date = Date.current - 1.day
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"), date: first_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: first_date, positions: [ first ])
    )
    first_holding = @provider_account.account.holdings.find_by!(date: first_date)
    first_holding.set_manual_cost_basis!(BigDecimal("35"))
    provider_security = first_holding.provider_security
    remapped_security = Security.create!(ticker: "CUSTOM:APPLE-REOPEN", name: "Personal Apple")
    first_holding.remap_security!(remapped_security)

    reopen_date = first_date.next_day
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: reopen_date, positions: [])
    )
    tombstone = @provider_account.account.holdings.find_by!(date: reopen_date)
    assert_equal BigDecimal("0"), tombstone.qty
    assert_nil tombstone.cost_basis

    reopened = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("120"), cost_basis: BigDecimal("52"), date: reopen_date)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: reopen_date, positions: [ reopened ])
    )

    reopened_holding = @provider_account.account.holdings.find_by!(date: reopen_date)
    assert_equal BigDecimal("52"), reopened_holding.cost_basis
    assert_equal "provider", reopened_holding.cost_basis_source
    assert_not reopened_holding.cost_basis_locked?
    assert_equal remapped_security.id, reopened_holding.security_id
    assert_equal provider_security.id, reopened_holding.provider_security_id
  end

  test "clears an unlocked stale provider basis when the bank average is unavailable" do
    first = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"))
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: Date.current, positions: [ first ])
    )
    holding = @provider_account.account.holdings.sole
    assert_equal "provider", holding.cost_basis_source

    refreshed = normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("110"), cost_basis: nil)
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(date: Date.current, positions: [ refreshed ])
    )

    assert_nil holding.reload.cost_basis
    assert_nil holding.cost_basis_source
  end

  test "refreshes the provider basis of an exactly validated generated projection" do
    previous_date = Date.current - 1.day
    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(
        date: previous_date,
        positions: [ normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("100"), cost_basis: BigDecimal("40"), date: previous_date) ]
      )
    )
    security = @provider_account.account.holdings.sole.security
    provider_id = @provider_account.account_provider.id
    projected = Holding::DirectaSnapshotCalculator.new(
      @provider_account.account,
      account_provider_id: provider_id
    ).projected_rows.find { |row| row.date == Date.current }
    assert projected

    generated = @provider_account.account.holdings.create!(
      security: security,
      qty: projected.qty,
      price: projected.price,
      amount: projected.amount,
      currency: projected.currency,
      date: projected.date,
      cost_basis: projected.cost_basis,
      cost_basis_source: "calculated"
    )
    validator = DirectaAccount::ContentValidator.new(@provider_account)
    assert validator.generated_snapshot_holding?(generated)

    DirectaAccount::HoldingsProcessor.new(@provider_account).process(
      normalized_snapshot(
        date: Date.current,
        positions: [ normalized_position(quantity: BigDecimal("1"), amount: BigDecimal("110"), cost_basis: BigDecimal("44")) ]
      )
    )

    imported = generated.reload
    assert_equal BigDecimal("44"), imported.cost_basis
    assert_equal "provider", imported.cost_basis_source
    assert_equal provider_id, imported.account_provider_id
    assert_equal "directa-position-US0378331005-XNAS-#{Date.current.iso8601}", imported.external_id
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

    def normalized_position(quantity:, amount:, cost_basis: nil, date: Date.current)
      DirectaItem::PortfolioNormalizer::Position.new(
        isin: "US0378331005",
        mic: "XNAS",
        name: "Apple Inc.",
        quantity: quantity,
        market_value: amount,
        price: amount / quantity,
        cost_basis: cost_basis,
        external_id: "directa-position-US0378331005-XNAS-#{date.iso8601}",
        metadata: [ { "univoco" => "synthetic-position" } ]
      )
    end
end
