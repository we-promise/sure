require "test_helper"

class DirectaItem::HistorySyncerTest < ActiveSupport::TestCase
  Normalized = Struct.new(:activities, :cohorts)
  ActivityIdentity = Struct.new(:external_id, :fingerprint)

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @item = DirectaItem.create!(
      family: @family,
      owner: @owner,
      broker_account: "00123",
      account_identity: "verified-account-123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      connection_generation: 3,
      status: :connected
    )
    DirectaItem::Importer.new(@item).import(snapshot: provider_snapshot)
    @provider_account = @item.directa_account
    @session = @item.verified_session
    @item.stubs(:verified_session).returns(@session)
  end

  test "imports two complete matching passes with validated statement scopes" do
    coverage_start = DirectaItem::HistorySyncer::MINIMUM_DATE
    coverage_end = Time.find_zone!(Provider::Directa::History::BANK_TIME_ZONE).today - 1.day
    order = order_row(coverage_end - 5.days)
    orders = [ order ].freeze
    statement_date = statement_date_for(order.fetch("DataEvento"), coverage_end)
    body = "synthetic statement".b
    orders_result = orders_result(orders, coverage_start, coverage_end)
    statement_result = statement_result(statement_date, body)
    readers = [ mock("first Directa history pass"), mock("second Directa history pass") ]

    readers.each do |reader|
      reader.expects(:fetch_orders).with(date_from: coverage_start, date_to: coverage_end).returns(orders_result)
      reader.expects(:fetch_statement).with(date: statement_date).returns(statement_result)
    end
    Provider::Directa::History.expects(:new).with(session: @session, http_transport: anything).twice.returns(*readers)

    normalized = normalized_result
    normalizers = [ mock("first history normalizer"), mock("second history normalizer") ]
    normalizers.each { |normalizer| normalizer.expects(:normalize).returns(normalized) }
    DirectaItem::HistoryNormalizer.expects(:new).twice.returns(*normalizers)

    importer = mock("Directa history importer")
    DirectaItem::HistoryImporter.expects(:new).with(@item).returns(importer)
    importer.expects(:import).with do |arguments|
      arguments[:normalized] == normalized &&
        arguments[:coverage_start] == coverage_start &&
        arguments[:coverage_end] == coverage_end &&
        arguments[:scope].is_a?(DirectaItem::HistoryImporter::Scope) &&
        arguments[:scope].provider_account_id == @provider_account.id.to_s &&
        arguments[:scope].linked_account_id == @provider_account.account.id.to_s
    end.returns(3)

    assert DirectaItem::HistorySyncer.new(@item).perform
    assert_nil @item.reload.history_sync_error_code
  end

  test "rejects changed normalized passes without importing either result" do
    stub_two_passes(normalized: [ normalized_result, normalized_result(fingerprint: "b" * 64) ])
    DirectaItem::HistoryImporter.expects(:new).never

    refute DirectaItem::HistorySyncer.new(@item).perform

    assert_equal "history_changed", @item.reload.history_sync_error_code
  end

  test "rejects a statement response from another account identity" do
    coverage_start, coverage_end = expected_coverage
    statement_date = statement_date_for(order_row(coverage_end - 5.days).fetch("DataEvento"), coverage_end)
    bad_scope = Provider::Directa::History::SessionScope.new(
      account_number: @session.account_number,
      account_identity: "another-account",
      connection_generation: @session.connection_generation
    )
    reader = mock("Directa history reader")
    reader.expects(:fetch_orders).returns(orders_result([ order_row(coverage_end - 5.days) ], coverage_start, coverage_end))
    reader.expects(:fetch_statement).returns(statement_result(statement_date, "synthetic".b, scope: bad_scope))
    Provider::Directa::History.expects(:new).with(session: @session, http_transport: anything).returns(reader)
    DirectaItem::HistoryNormalizer.expects(:new).never
    DirectaItem::HistoryImporter.expects(:new).never

    refute DirectaItem::HistorySyncer.new(@item).perform

    assert_equal "history_identity_changed", @item.reload.history_sync_error_code
  end

  test "stops before import when the connection generation changes during fetching" do
    coverage_start, coverage_end = expected_coverage
    order = order_row(coverage_end - 5.days)
    statement_date = statement_date_for(order.fetch("DataEvento"), coverage_end)
    reader = mock("Directa history reader")
    first_reader = mock("first Directa history reader")
    first_reader.expects(:fetch_orders).returns(orders_result([ order ], coverage_start, coverage_end))
    first_reader.expects(:fetch_statement).returns(statement_result(statement_date, "synthetic".b))
    second_reader = Object.new
    item = @item
    second_orders_result = orders_result([ order ], coverage_start, coverage_end)
    second_statement_result = statement_result(statement_date, "synthetic".b)
    second_reader.define_singleton_method(:fetch_orders) do |date_from:, date_to:|
      item.update!(connection_generation: 4, status: :requires_update)
      second_orders_result
    end
    second_reader.define_singleton_method(:fetch_statement) { |date:| second_statement_result }
    Provider::Directa::History.expects(:new).with(session: @session, http_transport: anything).twice.returns(first_reader, second_reader)
    normalizer = mock("history normalizer")
    normalizer.expects(:normalize).twice.returns(normalized_result)
    DirectaItem::HistoryNormalizer.expects(:new).twice.returns(normalizer)
    DirectaItem::HistoryImporter.expects(:new).never

    refute DirectaItem::HistorySyncer.new(@item).perform

    assert_equal 4, @item.reload.connection_generation
    assert_nil @item.history_sync_error_code
  end

  test "reuses complete ledger coverage while refreshing the three month overlap" do
    today = Time.find_zone!(Provider::Directa::History::BANK_TIME_ZONE).today
    coverage_start = today.months_ago(3).beginning_of_month
    coverage_end = today - 1.day
    cohorts = (coverage_start..coverage_end).to_h { |date| [ date.iso8601, {} ] }
    bank_scope = Digest::SHA256.hexdigest(JSON.generate([ @item.broker_account, @item.account_identity ]))
    @provider_account.update!(
      history_synced_at: Time.current,
      history_ledger: {
        "schema_version" => 1,
        "bank_scope" => bank_scope,
        "coverage_start" => coverage_start.iso8601,
        "coverage_end" => coverage_end.iso8601,
        "cohorts" => cohorts,
        "entries" => {}
      }
    )

    assert_equal [ coverage_start, coverage_end ], DirectaItem::HistorySyncer.new(@item).send(:coverage_for, @provider_account)
  end

  private

    def expected_coverage
      [ DirectaItem::HistorySyncer::MINIMUM_DATE,
        Time.find_zone!(Provider::Directa::History::BANK_TIME_ZONE).today - 1.day ]
    end

    def order_row(event_date)
      {
        "Riferimento" => "A" * 14,
        "DataImmissione" => event_date.strftime("%Y%m%d").to_i,
        "DataEvento" => event_date.strftime("%Y%m%d").to_i
      }
    end

    def statement_date_for(integer_date, coverage_end)
      date = Date.strptime(integer_date.to_s, "%Y%m%d")
      [ Date.new(date.year, date.month, -1), coverage_end ].min
    end

    def orders_result(orders, date_from, date_to)
      Provider::Directa::History::OrdersResult.new(
        scope: session_scope,
        date_from: date_from,
        date_to: date_to,
        orders: orders,
        complete: true,
        fetched_at: Time.current
      )
    end

    def statement_result(date, body, scope: session_scope)
      Provider::Directa::History::StatementResult.new(
        scope: scope,
        date: date,
        body: body,
        source_encoding: Encoding::ISO_8859_1,
        fetched_at: Time.current
      )
    end

    def session_scope
      Provider::Directa::History::SessionScope.new(
        account_number: @session.account_number,
        account_identity: @session.account_identity,
        connection_generation: @session.connection_generation
      )
    end

    def normalized_result(fingerprint: "a" * 64)
      activity = ActivityIdentity.new("directa-history-v1:#{'c' * 64}", fingerprint)
      Normalized.new([ activity ], { "2026-05-01" => { fingerprint => 1 } })
    end

    def stub_two_passes(normalized:)
      coverage_start, coverage_end = expected_coverage
      event_date = coverage_end - 5.days
      order = order_row(event_date)
      statement_date = statement_date_for(event_date.strftime("%Y%m%d").to_i, coverage_end)
      readers = Array.new(2) { mock("Directa history reader") }
      readers.each do |reader|
        reader.expects(:fetch_orders).returns(orders_result([ order ], coverage_start, coverage_end))
        reader.expects(:fetch_statement).returns(statement_result(statement_date, "synthetic".b))
      end
      Provider::Directa::History.expects(:new).with(session: @session, http_transport: anything).twice.returns(*readers)

      normalizers = Array.new(2) { mock("history normalizer") }
      normalizers.zip(normalized).each { |normalizer, result| normalizer.expects(:normalize).returns(result) }
      DirectaItem::HistoryNormalizer.expects(:new).twice.returns(*normalizers)
    end

    def provider_snapshot
      Provider::Directa::Snapshot.new(
        account_number: "00123",
        account_identity: "verified-account-123",
        connection_generation: 3,
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
end
