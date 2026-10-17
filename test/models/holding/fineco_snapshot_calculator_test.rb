require "test_helper"

class Holding::FinecoSnapshotCalculatorTest < ActiveSupport::TestCase
  setup do
    Current.reset
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @security = Security.create!(
      ticker: "US0000000002",
      exchange_operating_mic: "XETR",
      name: "Synthetic listed fund",
      offline: false
    )
    @item = FinecoItem.new(
      family: @family,
      owner: @owner,
      gsessionid: "synthetic-session",
      account_index: "2",
      dossier_index: "11",
      bank_account_number: "SYNTHETIC-ACCOUNT",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
      captured_at: Time.current
    )
    Account.any_instance.stubs(:sync_later).returns(nil)
  end

  teardown { Current.reset }

  test "native materialization carries each Fineco snapshot across sale and recovery dates without global prices" do
    today = Date.current
    first_date = today - 4.days
    sale_date = today - 2.days
    recovery_date = today

    capture(first_date, [ etf_position(quantity: "2", book_value: "90", market_value: "100", market_price: "50", profit_loss: "10", accrual: "0.5") ])
    capture(sale_date, [], zero_summary)
    capture(recovery_date, [ etf_position(quantity: "3", book_value: "150", market_value: "180", market_price: "60", profit_loss: "30", accrual: "0") ])

    account = @item.accounts.sole
    provider_account = @item.fineco_accounts.sole
    Account.any_instance.stubs(:broadcast_refresh)
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Security::Price.create!(security: @security, date: today - 3.days, price: "98.5", currency: "GBP")
    Security::Price.create!(security: @security, date: today - 1.day, price: "123.45", currency: "GBP")
    @item.disconnect!

    Account.any_instance.unstub(:sync_later)
    account.sync_later
    sync = account.syncs.visible.sole
    sync.perform

    rows = account.holdings.where(security_id: @security.id).index_by(&:date)
    assert_equal [ first_date, first_date + 1.day, sale_date, sale_date + 1.day, recovery_date ].sort, rows.keys.sort
    assert_equal [ BigDecimal("2"), BigDecimal("2"), BigDecimal("0"), BigDecimal("0"), BigDecimal("3") ],
      [ first_date, first_date + 1.day, sale_date, sale_date + 1.day, recovery_date ].map { |date| rows.fetch(date).qty }
    assert_equal [ BigDecimal("100"), BigDecimal("100"), BigDecimal("0"), BigDecimal("0"), BigDecimal("180") ],
      [ first_date, first_date + 1.day, sale_date, sale_date + 1.day, recovery_date ].map { |date| rows.fetch(date).amount }
    assert_equal provider_account.account_provider.id, rows.fetch(first_date).account_provider_id
    assert_equal provider_account.account_provider.id, rows.fetch(sale_date).account_provider_id
    assert_equal provider_account.account_provider.id, rows.fetch(recovery_date).account_provider_id
    assert_equal "calculated", rows.fetch(first_date + 1.day).cost_basis_source
    assert_equal "calculated", rows.fetch(sale_date + 1.day).cost_basis_source
    assert @item.reload.requires_update?
    assert_equal BigDecimal("180"), account.reload.current_anchor_balance
    assert_not @security.reload.offline?
  end

  test "native gapfill preserves a nominal bond's exact EUR amount through a split despite GBP clean prices" do
    today = Date.current
    snapshot_date = today - 1.day
    bond_security = Security.create!(
      ticker: "US0000000010",
      exchange_operating_mic: "ETLX",
      name: "Synthetic nominal bond",
      offline: false
    )
    bond = {
      "instrId" => "US0000000010",
      "venueSystem" => "ETLX",
      "symbol" => "SYNTH-BOND",
      "description" => "Synthetic nominal bond",
      "type" => "bond",
      "currencyCd" => "GBP",
      "qty" => "10000",
      "avgPrice" => "95",
      "marketPrice" => "98.5",
      "bookValue" => "12000",
      "marketValue" => "12774.31",
      "profitLoss" => "774.31",
      "accrual" => "0"
    }
    capture(snapshot_date, [ bond ])
    account = @item.accounts.sole
    snapshot = account.holdings.find_by!(security_id: bond_security.id, date: snapshot_date)
    Security::Price.create!(security: bond_security, date: today, price: "98.5", currency: "GBP")
    Security::Split.create!(security: bond_security, ex_date: today, numerator: 2, denominator: 1, source: "synthetic")
    Account.any_instance.stubs(:broadcast_refresh)
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Family.any_instance.stubs(:broadcast_sync_complete)

    raw = Holding::FinecoSnapshotCalculator.new(
      account,
      account_provider_id: @item.fineco_accounts.sole.account_provider.id
    ).calculate.index_by(&:date)
    split_day = raw.fetch(today)

    assert_equal BigDecimal("12774.31"), snapshot.amount
    assert_equal BigDecimal("1.277431"), raw.fetch(snapshot_date).price
    assert_equal BigDecimal("20000"), split_day.qty
    assert_equal BigDecimal("12774.31"), split_day.amount
    assert_equal BigDecimal("0.6387155"), split_day.price

    Account.any_instance.unstub(:sync_later)
    account.sync_later
    account.syncs.visible.sole.perform

    materialized = account.holdings.find_by!(security_id: bond_security.id, date: today)
    assert_equal BigDecimal("20000"), materialized.qty
    assert_equal BigDecimal("12774.31"), materialized.amount
    assert_equal "GBP", @item.fineco_accounts.sole.raw_position_metadata.sole.fetch("quote_currency")
    assert_not bond_security.reload.offline?
  end

  test "a remapped snapshot replaces only its unlocked generated gap row on the next day" do
    today = Date.current
    first_date = today - 1.day
    capture(first_date, [ etf_position(quantity: "2", book_value: "90", market_value: "100", market_price: "50", profit_loss: "10", accrual: "0.5") ])
    account = @item.accounts.sole
    original_holding = account.holdings.sole
    remapped_security = Security.create!(
      ticker: "USER-REMAP",
      exchange_operating_mic: "XETR",
      name: "User selected security",
      offline: true
    )
    original_holding.update!(security: remapped_security, security_locked: true)
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.unstub(:sync_later)

    travel_to(Time.zone.local(today.year, today.month, today.day, 12)) do
      account.sync_later
      account.syncs.visible.sole.perform
    end

    calculated_row = account.holdings.find_by!(security_id: remapped_security.id, date: today)
    assert_nil calculated_row.account_provider_id
    assert_equal "calculated", calculated_row.cost_basis_source
    assert_not calculated_row.security_locked?

    updated = etf_position(quantity: "2", book_value: "90", market_value: "120", market_price: "60", profit_loss: "30", accrual: "0.5")
    capture(today, [ updated ])

    imported = account.holdings.find_by!(security_id: remapped_security.id, date: today)
    assert_equal BigDecimal("120"), imported.amount
    assert_equal original_holding.provider_security_id, imported.provider_security_id
    assert imported.security_locked?
    assert_equal @item.fineco_accounts.sole.account_provider.id, imported.account_provider_id
    assert_equal "fineco-position-US0000000002-XETR-#{today.iso8601}", imported.external_id
    assert_equal 1, account.holdings.where(security_id: remapped_security.id, date: today).count
  end

  test "a new snapshot replaces a generated gap row when cost basis is unknown" do
    today = Date.current
    first_date = today - 1.day
    position = etf_position(
      quantity: "2",
      book_value: "0",
      market_value: "100",
      market_price: "50",
      profit_loss: "100",
      accrual: "0"
    )
    capture(first_date, [ position ])
    account = @item.accounts.sole

    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.unstub(:sync_later)

    travel_to(Time.zone.local(today.year, today.month, today.day, 12)) do
      account.sync_later
      account.syncs.visible.sole.perform
    end

    generated = account.holdings.find_by!(security_id: @security.id, date: today)
    assert_nil generated.account_provider_id
    assert_nil generated.cost_basis
    assert_nil generated.cost_basis_source

    updated = position.merge(
      "marketValue" => "120",
      "marketPrice" => "60",
      "profitLoss" => "120"
    )
    capture(today, [ updated ])

    imported = account.holdings.find_by!(security_id: @security.id, date: today)
    assert_equal @item.fineco_accounts.sole.account_provider.id, imported.account_provider_id
    assert_equal BigDecimal("120"), imported.amount
    assert_equal "fineco-position-US0000000002-XETR-#{today.iso8601}", imported.external_id
    assert_equal 1, account.holdings.where(security_id: @security.id, date: today).count
  end

  test "a split projection matches persisted precision during the next snapshot refresh" do
    today = Date.current
    first_date = today - 1.day
    original = etf_position(
      quantity: "2",
      book_value: "154",
      market_value: "100",
      market_price: "50",
      profit_loss: "-54",
      accrual: "0"
    )
    capture(first_date, [ original ])
    account = @item.accounts.sole
    Security::Split.create!(
      security: @security,
      ex_date: today,
      numerator: 3,
      denominator: 2,
      source: "synthetic"
    )
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.unstub(:sync_later)

    travel_to(Time.zone.local(today.year, today.month, today.day, 12)) do
      account.sync_later
      account.syncs.visible.sole.perform
    end

    generated = account.holdings.find_by!(security_id: @security.id, date: today)
    assert_equal BigDecimal("3"), generated.qty
    assert_equal BigDecimal("100"), generated.amount
    assert_equal BigDecimal("51.3333"), generated.cost_basis
    assert FinecoAccount::ContentValidator.new(account, @item.fineco_accounts.sole).validate!

    refreshed = etf_position(
      quantity: "3",
      book_value: "154",
      market_value: "120",
      market_price: "40",
      profit_loss: "-34",
      accrual: "0"
    )
    capture(today, [ refreshed ])

    imported = account.holdings.find_by!(security_id: @security.id, date: today)
    assert_equal BigDecimal("3"), imported.qty
    assert_equal BigDecimal("120"), imported.amount
    assert_equal BigDecimal("51.3333"), imported.cost_basis
    assert_equal @item.fineco_accounts.sole.account_provider.id, imported.account_provider_id
  end

  private

    def capture(date, positions, summary = summary_for(positions))
      captured_at = Time.zone.local(date.year, date.month, date.day, 12)
      travel_to(captured_at) do
        @item.import_portfolio_snapshot!(
          payload: portfolio_payload(positions, summary),
          captured_at: captured_at
        )
      end
    end

    def portfolio_payload(positions, summary)
      currencies = positions.map { |position| position["currencyCd"] }.uniq.sort
      instrument_types = positions.map { |position| position["type"] }.uniq.sort
      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => currencies, "show" => currencies },
          "instrumentTypes" => { "total" => instrument_types, "show" => instrument_types }
        },
        "positions" => { "show" => positions.map(&:dup) },
        "summary" => { "show" => summary.dup, "total" => summary.dup }
      }
    end

    def summary_for(positions)
      book_value = positions.sum(BigDecimal("0")) { |position| BigDecimal(position.fetch("bookValue")) }
      market_value = positions.sum(BigDecimal("0")) { |position| BigDecimal(position.fetch("marketValue")) }
      profit_loss = positions.sum(BigDecimal("0")) { |position| BigDecimal(position.fetch("profitLoss")) }
      accrual = positions.sum(BigDecimal("0")) { |position| BigDecimal(position.fetch("accrual", "0")) }

      {
        "currencyCd" => "EUR",
        "bookValue" => book_value.to_s("F"),
        "marketValue" => market_value.to_s("F"),
        "profitLoss" => profit_loss.to_s("F"),
        "profitLossPerc" => "11.11",
        "accrual" => accrual.to_s("F")
      }
    end

    def zero_summary
      summary_for([])
    end

    def etf_position(quantity:, book_value:, market_value:, market_price:, profit_loss:, accrual:)
      {
        "instrId" => "US0000000002",
        "venueSystem" => "XETRA",
        "symbol" => "SYNTH",
        "description" => "Synthetic fund",
        "type" => "etf",
        "currencyCd" => "EUR",
        "qty" => quantity,
        "avgPrice" => "45",
        "marketPrice" => market_price,
        "bookValue" => book_value,
        "marketValue" => market_value,
        "profitLoss" => profit_loss,
        "accrual" => accrual
      }
    end
end
