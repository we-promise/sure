require "test_helper"

class DirectaItem::HistoryImporterTest < ActiveSupport::TestCase
  setup do
    Current.reset
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
      connection_generation: 5,
      status: :connected
    )
    @account = DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot).account
    @provider_account = @item.directa_accounts.sole
    @provider_link = @provider_account.account_provider
    @scope = build_scope
    @bank_scope = bank_scope
    @from = Date.new(2026, 5, 1)
    @to = Date.new(2026, 5, 31)
  end

  teardown { Current.reset }

  test "imports a cash-affecting trade and encrypts the complete account-scoped ledger" do
    activity = normalized_activity

    assert_equal 1, import(normalized([ activity ]))

    entry = @account.entries.find_by!(external_id: activity.external_id, source: "directa")
    trade = entry.entryable
    ledger = @provider_account.reload.history_ledger

    assert_equal BigDecimal("2"), trade.qty
    assert_equal BigDecimal("100"), trade.price
    assert_equal BigDecimal("1"), trade.fee
    assert_equal BigDecimal("201"), entry.amount
    assert_equal "EUR", entry.currency
    assert trade.directa_history_entry?(entry)
    assert trade.affects_cash_balance?(entry)
    assert_equal @provider_account.id.to_s, trade.extra.dig("directa", "provider_account_id")
    assert_equal @bank_scope, trade.extra.dig("directa", "bank_scope")
    assert_equal activity.fingerprint, trade.extra.dig("directa", "fingerprint")
    refute trade.extra.fetch("directa").key?("cash_account_external")

    assert_equal %w[bank_scope cohorts coverage_end coverage_start entries schema_version], ledger.keys.sort
    assert_equal 1, ledger.fetch("schema_version")
    assert_equal @bank_scope, ledger.fetch("bank_scope")
    assert_equal @from.iso8601, ledger.fetch("coverage_start")
    assert_equal @to.iso8601, ledger.fetch("coverage_end")
    assert_equal 31, ledger.fetch("cohorts").length
    assert_equal({ activity.fingerprint => 1 }, ledger.fetch("cohorts").fetch(activity.date.iso8601))
    assert_equal({ "fingerprint" => activity.fingerprint, "date" => activity.date.iso8601 }, ledger.fetch("entries").fetch(activity.external_id))
    assert @provider_account.history_synced_at.present?

    stored = raw_history_ledger
    refute_includes stored, "schema_version"
    refute_includes stored, activity.external_id
    refute_includes stored, activity.fingerprint
  end

  test "replay is idempotent and preserves user edits to an owned trade" do
    activity = normalized_activity
    assert_equal 1, import(normalized([ activity ]))
    entry = @account.entries.find_by!(external_id: activity.external_id, source: "directa")
    entry.update!(name: "User-edited activity", amount: 777, user_modified: true)
    entry.entryable.update!(qty: 9, price: 77)
    before_ledger = @provider_account.reload.history_ledger.deep_dup

    assert_equal 0, import(normalized([ activity ]))

    entry.reload
    entry.entryable.reload
    assert_equal "User-edited activity", entry.name
    assert_equal BigDecimal("777"), entry.amount
    assert_equal BigDecimal("9"), entry.entryable.qty
    assert_equal BigDecimal("77"), entry.entryable.price
    assert_equal before_ledger, @provider_account.reload.history_ledger
    assert_equal 1, @account.entries.where(source: "directa").count
  end

  test "does not recreate an owned activity after the user deletes its entry" do
    activity = normalized_activity
    import(normalized([ activity ]))
    @account.entries.find_by!(external_id: activity.external_id, source: "directa").destroy!
    before_ledger = @provider_account.reload.history_ledger.deep_dup

    assert_equal 0, import(normalized([ activity ]))

    assert_nil @account.entries.find_by(external_id: activity.external_id, source: "directa")
    assert_equal before_ledger, @provider_account.reload.history_ledger
  end

  test "fails closed when a previously covered fingerprint changes" do
    activity = normalized_activity
    import(normalized([ activity ]))
    old_ledger = @provider_account.reload.history_ledger.deep_dup
    old_trade = @account.entries.find_by!(external_id: activity.external_id, source: "directa").entryable

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      import(normalized([ normalized_activity(fingerprint: "b" * 64) ]))
    end

    assert_equal "history_changed", error.code
    assert_equal old_ledger, @provider_account.reload.history_ledger
    assert_equal 1, @account.entries.where(source: "directa").count
    assert_equal BigDecimal("2"), old_trade.reload.qty
  end

  test "rejects account generation and bank identity changes before importing" do
    activity = normalized_activity
    wrong_scope = build_scope(connection_generation: 6)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      DirectaItem::HistoryImporter.new(@item).import(
        normalized: normalized([ activity ]),
        coverage_start: @from,
        coverage_end: @to,
        scope: wrong_scope
      )
    end

    assert_equal "history_identity_changed", error.code
    assert_nil @provider_account.reload.history_ledger
    assert_empty @account.entries.where(source: "directa")
  end

  test "rejects an external id already owned by another source and rolls back the ledger" do
    activity = normalized_activity
    security = Security.create!(
      ticker: "MANUAL-HISTORY",
      name: "Manual activity",
      exchange_operating_mic: "XNAS",
      offline: true,
      offline_reason: "manual"
    )
    collision = @account.entries.create!(
      name: "Manual entry",
      date: activity.date,
      amount: activity.amount,
      currency: "EUR",
      source: "manual",
      external_id: activity.external_id,
      entryable: Trade.new(security: security, qty: 1, price: 5, currency: "EUR")
    )

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      import(normalized([ activity ]))
    end

    assert_equal "history_changed", error.code
    assert_equal "manual", collision.reload.source
    assert_nil @provider_account.reload.history_ledger
  end

  test "rejects a stored ledger scoped to a different Directa identity" do
    activity = normalized_activity
    import(normalized([ activity ]))
    wrong_ledger = @provider_account.reload.history_ledger.deep_dup
    wrong_ledger["bank_scope"] = "c" * 64
    @provider_account.update!(history_ledger: wrong_ledger)

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      import(normalized([ activity ]))
    end

    assert_equal "history_changed", error.code
    assert_equal wrong_ledger, @provider_account.reload.history_ledger
  end

  test "reuses an existing offline ISIN security without adding price-provider data" do
    isin = "US0378331005"
    security = Security.create!(
      ticker: isin,
      name: "Offline Apple identity",
      exchange_operating_mic: nil,
      offline: true,
      offline_reason: "directa_isin"
    )

    assert_equal 1, import(normalized([ normalized_activity(isin: isin) ]))

    trade = @account.entries.where(source: "directa").sole.entryable
    assert_equal security.id, trade.security_id
    assert security.reload.offline?
    assert_nil security.price_provider
  end

  test "uses the Directa account's latest provider security for a matching ISIN" do
    isin = "US0378331005"
    security = Security.create!(
      ticker: isin,
      name: "Directa held security",
      exchange_operating_mic: "XNAS",
      offline: true,
      offline_reason: "directa_isin"
    )
    @provider_link.holdings.create!(
      account: @account,
      security: security,
      provider_security: security,
      qty: 2,
      price: 100,
      amount: 200,
      currency: "EUR",
      date: Date.new(2026, 5, 2),
      external_id: "directa-position-#{isin}-XNAS-2026-05-02"
    )

    assert_equal 1, import(normalized([ normalized_activity(isin: isin) ]))

    trade = @account.entries.where(source: "directa").sole.entryable
    assert_equal security.id, trade.security_id
    assert_equal 0, Security.where(ticker: isin, exchange_operating_mic: nil).count
  end

  test "accepts a trade whose proceeds are fully offset by its reported fee" do
    activity = normalized_activity(quantity: BigDecimal("-2"), amount: BigDecimal("0"))

    assert_equal 1, import(normalized([ activity ]))

    entry = @account.entries.find_by!(external_id: activity.external_id, source: "directa")
    assert_equal BigDecimal("-2"), entry.entryable.qty
    assert_equal BigDecimal("0"), entry.amount
  end

  test "rejects coverage through the current Europe Rome date" do
    activity = normalized_activity
    bank_today = Time.current.in_time_zone("Europe/Rome").to_date

    error = assert_raises(DirectaItem::PortfolioNormalizer::Error) do
      import(normalized([ activity ]), to: bank_today)
    end

    assert_equal "history_invalid_data", error.code
    assert_nil @provider_account.reload.history_ledger
  end

  private

    def import(result, scope: @scope, from: @from, to: @to)
      DirectaItem::HistoryImporter.new(@item).import(
        normalized: result,
        coverage_start: from,
        coverage_end: to,
        scope: scope
      )
    end

    def normalized(activities)
      cohorts = activities.group_by { |activity| activity.date.iso8601 }.transform_values do |day_activities|
        day_activities.each_with_object(Hash.new(0)) do |activity, counts|
          counts[activity.fingerprint] += 1
        end.sort.to_h
      end
      DirectaItem::HistoryNormalizer::Result.new(activities: activities, cohorts: cohorts)
    end

    def normalized_activity(fingerprint: "a" * 64, isin: "US0378331005", quantity: BigDecimal("2"), amount: BigDecimal("201"), fee: BigDecimal("1"))
      date = Date.new(2026, 5, 3)
      DirectaItem::HistoryNormalizer::Activity.new(
        date: date,
        isin: isin,
        name: "Synthetic Directa security",
        quantity: quantity,
        price: BigDecimal("100"),
        amount: amount,
        fee: fee,
        currency: "EUR",
        external_id: "directa-history-v1:#{Digest::SHA256.hexdigest("synthetic-reference-#{date.iso8601}")}",
        fingerprint: fingerprint,
        occurrence: 1,
        metadata: {
          "aggregation" => "executed_order_day",
          "quote_currency" => "USD",
          "original_prices" => [ "100,00" ],
          "fill_count" => 1,
          "commission_reported" => true,
          "commission_reported_fill_count" => 1,
          "fee_scope" => "reported_statement_commission_only",
          "gross_eur" => "-200,00",
          "value_dates" => [ "2026-05-05" ]
        }
      )
    end

    def build_scope(connection_generation: @item.connection_generation)
      DirectaItem::HistoryImporter::Scope.new(
        account_number: @item.broker_account,
        account_identity: @item.account_identity,
        connection_generation: connection_generation,
        owner_id: @item.owner_id,
        family_id: @item.family_id,
        provider_account_id: @provider_account.id,
        linked_account_id: @account.id,
        account_provider_id: @provider_link.id
      )
    end

    def bank_scope
      Digest::SHA256.hexdigest(JSON.generate([ @item.broker_account, @item.account_identity ]))
    end

    def raw_history_ledger
      ActiveRecord::Base.connection.select_value(
        "SELECT history_ledger::text FROM directa_accounts WHERE id = #{ActiveRecord::Base.connection.quote(@provider_account.id)}"
      )
    end

    def provider_snapshot
      amount = BigDecimal("100")
      Provider::Directa::Snapshot.new(
        account_number: @item.broker_account,
        account_identity: @item.account_identity,
        connection_generation: @item.connection_generation,
        observed_at: Time.current,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: true,
        cash: Provider::Directa::Cash.new(
          amount: amount,
          raw_amount: amount.to_s,
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
end
