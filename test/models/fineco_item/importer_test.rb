require "test_helper"

class FinecoItem::ImporterTest < ActiveSupport::TestCase
  setup do
    Current.reset
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @before_account_ids = @family.accounts.ids
    @before_enable_banking_provider_ids = AccountProvider.where(provider_type: "EnableBankingAccount").ids
    @item = build_item
  end

  teardown { Current.reset }

  test "closed identity capability blocks import before account creation or sync scheduling" do
    Provider::Fineco.stubs(:verified_identity_contract?).returns(false)
    FinecoItem::Importer.expects(:new).never
    Account.any_instance.expects(:sync_later).never

    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    end

    assert_equal "identity_verification_required", error.code
    assert @item.new_record?
    assert_equal @before_account_ids, @family.accounts.ids
    assert_empty @family.fineco_items
  end

  test "closed identity capability removes an imported item from sync eligibility" do
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(false)

    assert @item.session_configured?
    assert_not @item.ready_for_sync?
    assert_not @item.syncable?
    assert_not FinecoItem.syncable.exists?(id: @item.id)
  end

  test "creates a separate Fineco Investment account with zero cash and a native provider link" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)

    account = @item.accounts.sole
    holding = account.holdings.sole

    assert account.investment?
    assert_equal @family.id, account.family_id
    assert_equal @owner.id, account.owner_id
    assert_equal "EUR", account.currency
    assert_equal BigDecimal("100"), account.balance
    assert_equal BigDecimal("0"), account.cash_balance
    assert_equal "FinecoBank", account.institution_name
    assert_equal "finecobank.com", account.institution_domain
    assert_equal "FinecoAccount", account.account_providers.sole.provider_type
    assert_instance_of Provider::FinecoAdapter, account.account_providers.sole.adapter
    assert_equal BigDecimal("2"), holding.qty
    assert_equal BigDecimal("50"), holding.price
    assert_equal BigDecimal("100"), holding.amount
    assert_equal BigDecimal("45"), holding.cost_basis
    assert_equal "EUR", holding.currency
    assert_equal account.id, @item.fineco_accounts.sole.account.id
    assert_equal @before_account_ids, @family.accounts.where.not(id: account.id).ids
    assert_equal @before_enable_banking_provider_ids, AccountProvider.where(provider_type: "EnableBankingAccount").ids
  end

  test "same-day updates are idempotent and anchor the balance to provider holdings" do
    captured_at = Time.current
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: captured_at)
    account = @item.accounts.sole
    anchor_count = account.valuations.current_anchor.count

    updated_etf = ETF.merge("marketValue" => "120", "marketPrice" => "60", "profitLoss" => "30")
    updated_summary = summary_payload(market_value: "120", profit_loss: "30", profit_loss_perc: "33.33")
    @item.import_portfolio_snapshot!(payload: payload(positions: [ updated_etf ], summary: updated_summary), captured_at: captured_at + 1.hour)

    assert_equal 1, account.holdings.where(date: captured_at.to_date).count
    assert_equal anchor_count, account.valuations.current_anchor.count
    assert_equal BigDecimal("120"), account.valuations.current_anchor.sole.entry.amount
    assert_equal BigDecimal("120"), account.reload.balance
    assert_equal BigDecimal("0"), account.cash_balance
    assert_equal captured_at.to_date, account.latest_provider_holdings_snapshot_date
  end

  test "rejects an older same-day snapshot without replacing newer holdings or balance" do
    newer_capture = Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 12)
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: newer_capture)
    account = @item.accounts.sole
    prior_holding = account.holdings.sole.attributes
    updated = ETF.merge("marketValue" => "120", "marketPrice" => "60", "profitLoss" => "30")
    updated_summary = summary_payload(market_value: "120", profit_loss: "30", profit_loss_perc: "33.33")

    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(
        payload: payload(positions: [ updated ], summary: updated_summary),
        captured_at: newer_capture - 1.minute
      )
    end

    assert_equal "stale_snapshot", error.code
    assert_equal newer_capture, @item.reload.portfolio_snapshot_at
    assert_equal prior_holding, account.holdings.sole.attributes
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal newer_capture, @item.fineco_accounts.sole.last_snapshot_at
  end

  test "a next-day empty snapshot creates zero-quantity tombstones and prevents stale holdings resurfacing" do
    first_date = Date.current
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole

    travel_to(first_date + 1.day) do
      @item.import_portfolio_snapshot!(
        payload: payload(positions: [], summary: summary_payload(book_value: "0", market_value: "0", profit_loss: "0", profit_loss_perc: "0", accrual: "0")),
        captured_at: Time.current
      )
    end

    assert_equal [ BigDecimal("2"), BigDecimal("0") ], account.holdings.order(:date).pluck(:qty)
    assert_equal first_date + 1.day, account.latest_provider_holdings_snapshot_date
    assert_empty account.current_holdings
    assert_equal BigDecimal("0"), account.reload.balance
    assert_equal BigDecimal("0"), account.cash_balance
  end

  test "retains the prior holdings and anchor when one position is unsupported or the snapshot is partial" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole
    previous_snapshot_at = @item.portfolio_snapshot_at
    previous_holding = account.holdings.sole.attributes

    unsupported = ETF.merge("type" => "option", "marketValue" => "200")
    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(payload: payload(positions: [ unsupported ]), captured_at: Time.current + 1.day)
    end

    assert_equal "unsupported_position", error.code
    assert_equal 1, account.holdings.count
    assert_equal previous_holding, account.holdings.sole.attributes
    assert_equal BigDecimal("100"), account.balance
    assert_equal previous_snapshot_at, @item.portfolio_snapshot_at
  end

  test "preserves the GBP bond quote privately while using EUR effective value and basis" do
    bond = ETF.merge(
      "instrId" => "US0000000010",
      "venueSystem" => "ETLX",
      "type" => "bond",
      "currencyCd" => "GBP",
      "marketPrice" => "98.5",
      "accrual" => "0.5"
    )
    @item.import_portfolio_snapshot!(payload: payload(positions: [ bond ]), captured_at: Time.current)

    account = @item.accounts.sole
    holding = account.holdings.sole
    provider_account = @item.fineco_accounts.sole
    stored_metadata = ActiveRecord::Base.connection.select_value(
      "SELECT raw_position_metadata::text FROM fineco_accounts WHERE id = #{ActiveRecord::Base.connection.quote(provider_account.id)}"
    )

    assert_equal "EUR", account.currency
    assert_equal BigDecimal("50"), holding.price
    assert_equal BigDecimal("100"), holding.amount
    assert_equal BigDecimal("45"), holding.cost_basis
    assert_equal "GBP", provider_account.raw_position_metadata.first.fetch("quote_currency")
    assert_equal "98.5", provider_account.raw_position_metadata.first.fetch("quote_price")
    refute_includes stored_metadata, "GBP"
    refute_includes stored_metadata, "98.5"
  end

  test "respects user-locked security and cost basis while refreshing provider values" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    holding = @item.accounts.sole.holdings.sole
    user_security = Security.create!(ticker: "USER-LOCKED", exchange_operating_mic: "XETR", name: "User security", offline: true)
    holding.update!(
      security: user_security,
      security_locked: true,
      cost_basis: 77,
      cost_basis_source: "manual",
      cost_basis_locked: true
    )

    updated = ETF.merge("marketValue" => "120", "marketPrice" => "60", "profitLoss" => "30")
    @item.import_portfolio_snapshot!(
      payload: payload(positions: [ updated ], summary: summary_payload(market_value: "120", profit_loss: "30", profit_loss_perc: "33.33")),
      captured_at: Time.current
    )

    holding.reload
    assert_equal user_security.id, holding.security_id
    assert holding.security_locked?
    assert_equal BigDecimal("77"), holding.cost_basis
    assert holding.cost_basis_locked?
    assert_equal BigDecimal("120"), holding.amount
  end

  test "rejects an existing manual holding collision without changing prior provider data" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole
    prior_balance = account.balance
    second = ETF.merge(
      "instrId" => "US0000000010",
      "venueSystem" => "ETLX",
      "type" => "bond",
      "marketValue" => "25",
      "bookValue" => "20",
      "profitLoss" => "5"
    )
    second_security = Security.create!(ticker: second["instrId"], exchange_operating_mic: "ETLX", name: "Manual security", offline: true)
    manual_holding = account.holdings.create!(
      security: second_security,
      qty: 1,
      price: 25,
      amount: 25,
      currency: "EUR",
      date: Date.current
    )
    payload_with_collision = payload(
      positions: [ ETF, second ],
      summary: summary_payload(book_value: "110", market_value: "125", profit_loss: "15", accrual: "1.0")
    )

    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(payload: payload_with_collision, captured_at: Time.current)
    end

    assert_equal "holding_conflict", error.code
    assert_equal prior_balance, account.reload.balance
    assert_equal 1, account.holdings.where(account_provider_id: @item.fineco_accounts.sole.account_provider.id).count
    assert manual_holding.reload.persisted?
  end

  test "rejects unrelated manual holdings before changing the Fineco snapshot or balance" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole
    previous_snapshot_at = @item.portfolio_snapshot_at
    previous_holding = account.holdings.sole.attributes
    unrelated_security = Security.create!(
      ticker: "US0000000010",
      exchange_operating_mic: "ETLX",
      name: "Unrelated manual security",
      offline: true
    )
    manual_holding = account.holdings.create!(
      security: unrelated_security,
      qty: 1,
      price: 25,
      amount: 25,
      currency: "EUR",
      date: Date.current
    )

    materializer_error = assert_raises FinecoItem::PortfolioImportError do
      Holding::FinecoSnapshotCalculator.new(
        account,
        account_provider_id: @item.fineco_accounts.sole.account_provider.id
      ).calculate
    end
    assert_equal "account_content_conflict", materializer_error.code

    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current + 1.day)
    end

    assert_equal "account_content_conflict", error.code
    assert_equal previous_snapshot_at, @item.reload.portfolio_snapshot_at
    assert_equal previous_holding, account.holdings.find_by!(external_id: previous_holding.fetch("external_id")).attributes
    assert manual_holding.reload.persisted?
    assert_equal BigDecimal("100"), account.reload.balance
  end

  test "disconnect pauses Fineco while preserving provider snapshots through a native account sync" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole
    holding = account.holdings.sole
    account_provider_id = holding.account_provider_id
    original_generation = @item.connection_generation

    @item.disconnect!
    sync = account.syncs.visible.first
    sync.perform

    assert @item.reload.requires_update?
    assert_nil @item.gsessionid
    assert_equal account_provider_id, holding.reload.account_provider_id
    assert_equal BigDecimal("2"), account.current_holdings.sole.qty
    assert_equal BigDecimal("100"), account.balance
    assert_equal BigDecimal("0"), account.cash_balance
    assert_equal account_provider_id, account.account_providers.sole.id
    assert_equal original_generation + 1, @item.connection_generation
  end

  test "a scheduled snapshot does not recreate a user-deleted Investment account" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole
    account.destroy!
    accounts_after_delete = @family.accounts.count

    assert_not @item.account_link_ready?
    assert_not @item.syncable?
    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current + 1.day)
    end

    assert_equal "account_conflict", error.code
    assert_equal accounts_after_delete, @family.accounts.count
    assert @item.fineco_account.persisted?
    assert_nil @item.fineco_account.account_provider
  end

  test "automatic sync requires an active owner and a matching Investment account mapping" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole

    assert @item.syncable?
    assert FinecoItem.syncable.exists?(id: @item.id)

    @owner.update_column(:active, false)
    assert_not @item.reload.syncable?
    assert_not FinecoItem.syncable.exists?(id: @item.id)

    @owner.update_column(:active, true)
    account.update_column(:owner_id, users(:family_member).id)
    assert_not @item.reload.account_link_ready?
    assert_not FinecoItem.syncable.exists?(id: @item.id)
  end

  test "rejects positions that collide after carrying a user-locked security remap forward" do
    @item.import_portfolio_snapshot!(payload: payload(positions: [ ETF ]), captured_at: Time.current)
    account = @item.accounts.sole
    original_holding = account.holdings.sole
    remapped_security = Security.create!(
      ticker: "US0000000010",
      exchange_operating_mic: "XETR",
      name: "User remap target",
      offline: true
    )
    original_holding.update!(security: remapped_security, security_locked: true)
    original_snapshot_at = @item.portfolio_snapshot_at

    second = ETF.merge(
      "instrId" => "US0000000010",
      "type" => "etf",
      "qty" => "1",
      "avgPrice" => "15",
      "marketPrice" => "20",
      "bookValue" => "15",
      "marketValue" => "20",
      "profitLoss" => "5",
      "accrual" => "0"
    )
    next_day_summary = summary_payload(
      book_value: "105",
      market_value: "120",
      profit_loss: "15",
      profit_loss_perc: "14.29",
      accrual: "0.5"
    )

    error = assert_raises FinecoItem::PortfolioImportError do
      @item.import_portfolio_snapshot!(
        payload: payload(positions: [ ETF, second ], summary: next_day_summary),
        captured_at: Time.current + 1.day
      )
    end

    assert_equal "holding_conflict", error.code
    assert_equal original_snapshot_at, @item.reload.portfolio_snapshot_at
    assert_equal 1, account.holdings.count
    assert_equal BigDecimal("100"), account.reload.balance
    assert_equal remapped_security.id, original_holding.reload.security_id
    assert original_holding.security_locked?
  end

  private

    ETF = {
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
      "accrual" => "0.5",
      "ongoingAccrual" => "0.25"
    }.freeze

    def build_item
      FinecoItem.new(
        family: @family,
        owner: @owner,
        gsessionid: "synthetic-session",
        account_index: "2",
        dossier_index: "11",
        bank_account_number: "SYNTHETIC-ACCOUNT",
        dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
        captured_at: Time.current
      )
    end

    def payload(positions:, summary: nil)
      summary ||= summary_payload
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

    def summary_payload(book_value: "90", market_value: "100", profit_loss: "10", profit_loss_perc: "11.11", accrual: "0.5")
      {
        "currencyCd" => "EUR",
        "bookValue" => book_value,
        "marketValue" => market_value,
        "profitLoss" => profit_loss,
        "profitLossPerc" => profit_loss_perc,
        "accrual" => accrual
      }
    end
end
