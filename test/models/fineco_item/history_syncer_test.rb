require "test_helper"

class FinecoItem::HistorySyncerTest < ActiveSupport::TestCase
  setup do
    Current.reset
    travel_to Time.find_zone!(Provider::Fineco::BANK_TIME_ZONE).local(2026, 10, 18, 12)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
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
    @item.import_portfolio_snapshot!(payload: portfolio_payload, captured_at: Time.current)
    @account = @item.fineco_account
    @bank_today = Time.find_zone!(Provider::Fineco::BANK_TIME_ZONE).today
    @coverage_start = [ Date.new(2018, 1, 1), @bank_today.months_ago(3) ].max
    @coverage_end = @bank_today - 1.day
    @prior_ledger = {
      "version" => 1,
      "coverage_from" => "2018-01-01",
      "coverage_to" => @coverage_end.iso8601,
      "days" => {}
    }
    @account.update!(history_ledger: @prior_ledger, history_synced_at: Time.current)
  end

  teardown do
    travel_back
    Current.reset
  end

  test "imports only after two complete exports agree and clears the history error" do
    @item.update!(history_sync_error_code: "history_sync_failed")
    page = empty_page
    stub_verified_identity
    Provider::Fineco.any_instance.expects(:fetch_movements_window)
      .with(date_from: @coverage_start, date_to: @coverage_end, movement_type: "ORDER")
      .twice
      .returns(page)
    importer = mock
    FinecoItem::HistoryImporter.expects(:new).with(@item).returns(importer)
    importer.expects(:import).with(
      normalized: instance_of(FinecoItem::HistoryNormalizer::Result),
      coverage_start: @coverage_start,
      coverage_end: @coverage_end
    )

    assert FinecoItem::HistorySyncer.new(@item).perform

    assert_nil @item.reload.history_sync_error_code
    assert @account.reload.history_synced_at.present?
  end

  test "splits a capped export window before importing its two-pass coverage" do
    stub_verified_identity
    Provider::Fineco.any_instance.expects(:fetch_movements_window)
      .times(4)
      .raises(Provider::Fineco::MovementsWindowTooLarge)
      .then.returns(empty_page)
    importer = mock
    FinecoItem::HistoryImporter.expects(:new).with(@item).returns(importer)
    importer.expects(:import).with(any_parameters)

    assert FinecoItem::HistorySyncer.new(@item).perform
  end

  test "does not import a changing second export or advance the saved coverage" do
    before_ledger = @account.history_ledger.deep_dup
    before_synced_at = @account.history_synced_at
    before_snapshot_at = @item.portfolio_snapshot_at
    before_holdings = @account.current_account.holdings.order(:id).map(&:attributes)
    stub_verified_identity
    Provider::Fineco.any_instance.stubs(:fetch_movements_window)
      .returns(empty_page, movement_page([ movement_row ]))
    FinecoItem::HistoryImporter.expects(:new).never

    refute FinecoItem::HistorySyncer.new(@item).perform

    @item.reload
    @account.reload
    assert_equal "history_inconsistent", @item.history_sync_error_code
    assert_equal before_ledger, @account.history_ledger
    assert_equal before_synced_at, @account.history_synced_at
    assert_equal before_snapshot_at, @item.portfolio_snapshot_at
    assert_equal before_holdings, @account.current_account.holdings.order(:id).map(&:attributes)
    assert @item.good?
    assert_equal "synthetic-session", @item.gsessionid
  end

  test "rejects a repeated prior-year movement returned outside the requested window" do
    prior_day = Date.new(2025, 12, 31)
    @account.update!(
      history_ledger: {
        "version" => 1,
        "coverage_from" => "2024-12-31",
        "coverage_to" => "2024-12-31",
        "days" => {}
      },
      history_synced_at: Time.current
    )
    before_ledger = @account.history_ledger.deep_dup
    stub_verified_identity
    Provider::Fineco.any_instance.expects(:fetch_movements_window)
      .with(date_from: Date.new(2025, 1, 1), date_to: prior_day, movement_type: "ORDER")
      .returns(movement_page([ movement_row(transaction_date: "2025-12-31T12:00:00+01:00") ]))
    Provider::Fineco.any_instance.expects(:fetch_movements_window)
      .with(date_from: Date.new(2026, 1, 1), date_to: @coverage_end, movement_type: "ORDER")
      .returns(movement_page([ movement_row(transaction_date: "2025-12-31T12:00:00+01:00") ]))
    FinecoItem::HistoryImporter.expects(:new).never

    refute FinecoItem::HistorySyncer.new(@item).perform

    @item.reload
    @account.reload
    assert_equal "history_incomplete", @item.history_sync_error_code
    assert_equal before_ledger, @account.history_ledger
    assert @item.good?
  end

  test "restarts both exports from Fineco's validated minimum available date" do
    earliest_date = Date.new(2022, 10, 19)
    @account.update!(history_ledger: nil, history_synced_at: nil)
    stub_verified_identity
    Provider::Fineco.any_instance.expects(:fetch_movements_window)
      .times(11)
      .raises(Provider::Fineco::MovementsDateRangeUnavailable.new(earliest_date))
      .then.returns(empty_page)
    importer = mock
    FinecoItem::HistoryImporter.expects(:new).with(@item).returns(importer)
    importer.expects(:import).with(
      normalized: instance_of(FinecoItem::HistoryNormalizer::Result),
      coverage_start: earliest_date,
      coverage_end: @coverage_end
    )

    assert FinecoItem::HistorySyncer.new(@item).perform
  end

  test "caps recursive window splitting and leaves prior history untouched" do
    before_ledger = @account.history_ledger.deep_dup
    before_synced_at = @account.history_synced_at
    stub_verified_identity
    Provider::Fineco.any_instance.expects(:fetch_movements_window)
      .times(FinecoItem::HistorySyncer::MAX_REQUESTS_PER_PASS)
      .raises(Provider::Fineco::MovementsWindowTooLarge)
    FinecoItem::HistoryImporter.expects(:new).never

    refute FinecoItem::HistorySyncer.new(@item).perform

    @item.reload
    @account.reload
    assert_equal "history_incomplete", @item.history_sync_error_code
    assert_equal before_ledger, @account.history_ledger
    assert_equal before_synced_at, @account.history_synced_at
    assert @item.good?
    assert_equal "synthetic-session", @item.gsessionid
  end

  test "persists a verified cookie rotation on a later provider failure" do
    stub_verified_identity(rotation: "rotated-session")
    Provider::Fineco.any_instance.stubs(:fetch_movements_window)
      .raises(Provider::Fineco::InvalidResponse, "private provider detail")
    FinecoItem::HistoryImporter.expects(:new).never

    refute FinecoItem::HistorySyncer.new(@item).perform

    @item.reload
    assert_equal "rotated-session", @item.gsessionid
    assert_equal "history_incomplete", @item.history_sync_error_code
    assert @item.good?
  end

  test "uses the verified rotated cookie on the next export request" do
    first_client = mock
    second_client = mock
    first_client.stubs(:last_verified_bank_identity).returns(verified_identity)
    first_client.stubs(:last_rotated_gsessionid).returns("rotated-session")
    second_client.stubs(:last_verified_bank_identity).returns(verified_identity)
    second_client.stubs(:last_rotated_gsessionid).returns(nil)
    first_client.expects(:fetch_movements_window)
      .with(date_from: @coverage_start, date_to: @coverage_end, movement_type: "ORDER")
      .returns(empty_page(rotation: "rotated-session"))
    second_client.expects(:fetch_movements_window)
      .with(date_from: @coverage_start, date_to: @coverage_end, movement_type: "ORDER")
      .returns(empty_page)
    Provider::Fineco.expects(:new).with(
      gsessionid: "synthetic-session", account_index: "2", dossier_index: "11"
    ).returns(first_client)
    Provider::Fineco.expects(:new).with(
      gsessionid: "rotated-session", account_index: "2", dossier_index: "11"
    ).returns(second_client)
    importer = mock
    FinecoItem::HistoryImporter.expects(:new).with(@item).returns(importer)
    importer.expects(:import).with(any_parameters)

    assert FinecoItem::HistorySyncer.new(@item).perform
  end

  test "reauthentication clears the session without retaining a verified rotation" do
    stub_verified_identity(rotation: "rotated-session")
    Provider::Fineco.any_instance.stubs(:fetch_movements_window)
      .raises(Provider::Fineco::ReauthenticationRequired, "private auth detail")
    FinecoItem::HistoryImporter.expects(:new).never

    refute FinecoItem::HistorySyncer.new(@item).perform

    @item.reload
    assert @item.requires_update?
    assert_nil @item.gsessionid
    assert_nil @item.history_sync_error_code
    assert_equal "reauthentication_required", @item.last_sync_error_code
  end

  test "identity drift clears credentials and rejects the export" do
    stub_verified_identity(rotation: "must-not-save")
    page = empty_page(account_number: "OTHER-ACCOUNT")
    Provider::Fineco.any_instance.stubs(:fetch_movements_window).returns(page)
    FinecoItem::HistoryImporter.expects(:new).never

    refute FinecoItem::HistorySyncer.new(@item).perform

    @item.reload
    assert @item.requires_update?
    assert_nil @item.gsessionid
    assert_equal "history_identity_changed", @item.history_sync_error_code
    assert_equal "account_identity_changed", @item.last_sync_error_code
  end

  private

    def portfolio_payload
      position = {
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
        "accrual" => "0.5"
      }
      summary = {
        "currencyCd" => "EUR",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "profitLossPerc" => "11.11",
        "accrual" => "0.5"
      }

      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => [ "EUR" ], "show" => [ "EUR" ] },
          "instrumentTypes" => { "total" => [ "etf" ], "show" => [ "etf" ] }
        },
        "positions" => { "show" => [ position ] },
        "summary" => { "show" => summary, "total" => summary }
      }
    end

    def movement_row(transaction_date: nil)
      transaction_date ||= Time.find_zone!(Provider::Fineco::BANK_TIME_ZONE)
        .local(@coverage_start.year, @coverage_start.month, @coverage_start.day, 9)
        .iso8601
      {
        "type" => "ORDER",
        "transactionDate" => transaction_date,
        "valueDate" => "2025-01-17T00:00:00+01:00",
        "description" => "Synthetic purchase",
        "name" => "Synthetic fund",
        "isin" => "US0000000002",
        "sign" => "A",
        "amount" => "2.00",
        "currency" => "EUR",
        "price" => "50.00",
        "exchange" => "1.0000",
        "equivalentValue" => "100.00"
      }
    end

    def empty_page(account_number: @item.bank_account_number, dossier_identity: @item.dossier_identity, rotation: nil)
      movement_page([], account_number: account_number, dossier_identity: dossier_identity, rotation: rotation)
    end

    def movement_page(rows, account_number: @item.bank_account_number, dossier_identity: @item.dossier_identity, rotation: nil)
      Provider::Fineco::MovementsPage.new(
        payload: { "movements" => rows, "lastPage" => false, "limitedResult" => false },
        rotated_gsessionid: rotation,
        account_number: account_number,
        dossier_identity: dossier_identity
      )
    end

    def stub_verified_identity(rotation: nil)
      Provider::Fineco.any_instance.stubs(:last_verified_bank_identity).returns(verified_identity)
      Provider::Fineco.any_instance.stubs(:last_rotated_gsessionid).returns(rotation)
    end

    def verified_identity
      Provider::Fineco::VerifiedBankIdentity.new(
        account_number: @item.bank_account_number,
        dossier_identity: @item.dossier_identity
      )
    end
end
