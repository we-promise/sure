require "test_helper"

class EnableBankingItem::ImporterFullHistoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Compte courant",
      uid: "hash_full_history",
      account_id: "uuid-full-history",
      currency: "EUR"
    )

    @requests = []
    Setting.stubs(:syncs_include_pending).returns(false)
    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
  end

  test "first fetch uses strategy=longest with sync_start_date as date_from" do
    @enable_banking_item.update!(sync_start_date: Date.new(2020, 1, 1))
    link!

    build_importer(transactions: [ booked_tx("tx_new", 5.days.ago.to_date.iso8601) ]).import

    assert_equal 1, @requests.size
    assert_equal "longest", @requests.first[:strategy]
    assert_equal Date.new(2020, 1, 1), @requests.first[:date_from]
  end

  test "a future sync_start_date does not push the first fetch past today" do
    @enable_banking_item.update_columns(sync_start_date: 1.day.from_now.to_date)
    link!

    build_importer.import

    assert_equal "longest", @requests.first[:strategy]
    assert_equal Date.current, @requests.first[:date_from]
  end

  test "first fetch without sync_start_date sends no date_from and keeps all rows" do
    link!

    build_importer(transactions: [ booked_tx("tx_old", "2019-04-02"), booked_tx("tx_new", 5.days.ago.to_date.iso8601) ]).import

    assert_equal "longest", @requests.first[:strategy]
    assert_nil @requests.first[:date_from]
    assert_equal 2, @enable_banking_account.reload.raw_transactions_payload.size
  end

  test "later fetches are incremental and do not use strategy=longest" do
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", Date.current.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(1.day.ago)

    build_importer.import

    assert_equal 1, @requests.size
    assert_nil @requests.first[:strategy]
    assert_equal 8.days.ago.to_date, @requests.first[:date_from]
  end

  test "an empty first fetch is stored so the next fetch is incremental" do
    link!

    build_importer.import
    assert_equal [], @enable_banking_account.reload.raw_transactions_payload

    @enable_banking_item.stubs(:last_synced_at).returns(1.hour.ago)
    build_importer.import
    assert_nil @requests.last[:strategy], "an account without transactions gets strategy=longest on every sync"
  end

  test "an account with an empty stored payload is fetched over the 89-day window" do
    # Fetched empty, then unlinked while the item kept syncing, then relinked.
    @enable_banking_account.update!(raw_transactions_payload: [])
    link!
    @enable_banking_item.stubs(:last_synced_at).returns(1.hour.ago)

    build_importer.import

    assert_nil @requests.first[:strategy]
    assert_equal 89.days.ago.to_date, @requests.first[:date_from], "rows from the gap before the last sync are skipped"
  end

  test "an incremental fetch does not start before sync_start_date" do
    @enable_banking_item.update!(sync_start_date: 3.days.ago.to_date)
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", 2.days.ago.to_date.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(1.day.ago)

    build_importer(transactions: [ booked_tx("tx_before_start", 5.days.ago.to_date.iso8601) ]).import

    assert_equal 3.days.ago.to_date, @requests.first[:date_from]
    assert_equal %w[tx_stored], @enable_banking_account.reload.raw_transactions_payload.map { |row| row["transaction_id"] }
  end

  test "a future sync_start_date does not push an incremental fetch past today" do
    @enable_banking_item.update_columns(sync_start_date: 5.days.from_now.to_date)
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", 2.days.ago.to_date.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(1.day.ago)

    build_importer.import

    assert_equal Date.current, @requests.first[:date_from]
  end

  test "a failed first fetch stays a first fetch" do
    link!
    provider = mock()
    provider.stubs(:get_account_balances).returns(balances: [])
    provider.stubs(:get_account_transactions).raises(Provider::EnableBanking::EnableBankingError.new("boom", :request_failed))
    importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    importer.import

    assert_nil @enable_banking_account.reload.raw_transactions_payload
  end

  test "failed syncs after linking do not repeat strategy=longest" do
    Sync.create!(syncable: @enable_banking_item, status: "completed", completed_at: 2.days.ago, created_at: 2.days.ago)
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("a", 5.days.ago.to_date.iso8601) ])
    Sync.create!(syncable: @enable_banking_item, status: "failed", failed_at: 12.hours.ago, created_at: 12.hours.ago)

    build_importer.import

    assert_nil @requests.last[:strategy]
  end

  test "an incremental fetch starts before the newest stored row when the account was not fetched since" do
    # e.g. linked again, or linked to an existing account, after the item kept syncing
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", 20.days.ago.to_date.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(1.day.ago)

    build_importer.import

    assert_nil @requests.first[:strategy]
    assert_equal 27.days.ago.to_date, @requests.first[:date_from]
  end

  test "a dormant account's newest stored row pulls the incremental fetch back at most 89 days" do
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", 2.years.ago.to_date.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(1.day.ago)

    build_importer.import

    assert_nil @requests.first[:strategy]
    assert_equal 89.days.ago.to_date, @requests.first[:date_from]
  end

  test "a newest stored row 85 days old still keeps the incremental fetch within 89 days" do
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", 85.days.ago.to_date.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(1.day.ago)

    build_importer.import

    assert_equal 89.days.ago.to_date, @requests.first[:date_from]
  end

  test "a long outage still starts the incremental fetch 7 days before the last sync" do
    link!
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("tx_stored", 200.days.ago.to_date.iso8601) ])
    @enable_banking_item.stubs(:last_synced_at).returns(200.days.ago)

    build_importer.import

    assert_equal 207.days.ago.to_date, @requests.first[:date_from]
  end

  test "a longest first fetch is not cut at the incremental page cap" do
    link!
    pages = EnableBankingItem::Importer::MAX_PAGINATION_PAGES + 20
    importer = build_paging_importer(pages: pages)

    importer.import

    assert_equal pages, @requests.size
    assert @requests.all? { |params| params[:strategy] == "longest" }
    assert_equal pages, @enable_banking_account.reload.raw_transactions_payload.size
  end

  test "a longest first fetch still stops at its own page cap" do
    link!
    importer = build_paging_importer(pages: nil)

    importer.import

    assert_equal EnableBankingItem::Importer::MAX_LONGEST_PAGINATION_PAGES, @requests.size
  end

  test "a longest fetch cut at the page cap is reported as truncated, with a warning" do
    link!
    warnings = []
    Rails.logger.stubs(:warn).with { |msg| warnings << msg.to_s; true }

    result = build_paging_importer(pages: nil).import

    assert result[:success], "the partial history is kept and the sync does not fail"
    assert_equal 1, result[:transactions_truncated]
    assert_equal EnableBankingItem::Importer::MAX_LONGEST_PAGINATION_PAGES, @enable_banking_account.reload.raw_transactions_payload.size
    assert warnings.any? { |msg| msg.include?("may be incomplete") }, "no truncation warning logged"
  end

  test "a longest fetch cut at the page cap is captured as a debug log entry" do
    link!

    assert_difference -> { DebugLogEntry.where(provider_key: "enable_banking", category: "provider_sync_error").count }, 1 do
      build_paging_importer(pages: nil).import
    end

    entry = DebugLogEntry.last
    assert_equal @family, entry.family
    assert_equal @enable_banking_account.account_provider, entry.account_provider
    assert_equal EnableBankingItem::Importer::MAX_LONGEST_PAGINATION_PAGES, entry.metadata["transactions_kept"]
  end

  test "a longest fetch cut short by a mid-pagination validation error is reported as truncated" do
    link!
    provider = Object.new
    provider.define_singleton_method(:get_account_balances) { |**| { balances: [] } }
    provider.define_singleton_method(:get_account_transactions) do |**params|
      raise Provider::EnableBanking::EnableBankingError.new("Bad request", :bad_request) if params[:continuation_key]

      { transactions: [ { transaction_id: "a", booking_date: 300.days.ago.to_date.iso8601, status: "BOOK",
                          transaction_amount: { amount: "1.00", currency: "EUR" }, credit_debit_indicator: "DBIT" } ],
        continuation_key: "k1" }
    end
    importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    result = importer.import

    assert result[:success], "the rows from the first page are kept and the sync does not fail"
    assert_equal 1, result[:transactions_truncated]
    assert_equal 1, @enable_banking_account.reload.raw_transactions_payload.size
  end

  test "a complete fetch is not reported as truncated" do
    link!

    result = build_importer(transactions: [ booked_tx("a", 5.days.ago.to_date.iso8601) ]).import

    assert_equal 0, result[:transactions_truncated]
  end

  test "the pending fetch on a first fetch without sync_start_date sends a short window" do
    Setting.stubs(:syncs_include_pending).returns(true)
    link!

    build_importer.import

    book, pending = @requests
    assert_equal "BOOK", book[:transaction_status]
    assert_equal "longest", book[:strategy]
    assert_equal "PDNG", pending[:transaction_status]
    assert_nil pending[:strategy]
    assert_equal 30.days.ago.to_date, pending[:date_from]
  end

  private

    def build_importer(transactions: [])
      requests = @requests
      provider = mock()
      provider.stubs(:get_account_balances).returns(balances: [])
      provider.stubs(:get_account_transactions).with { |params| requests << params; true }.returns(transactions: transactions)
      importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: provider)
      importer.stubs(:fetch_session_data).returns(accounts: [])
      importer
    end

    # Each page returns one row and a continuation key, up to `pages` pages
    # (forever when nil).
    def build_paging_importer(pages:)
      requests = @requests
      test_case = self
      provider = Object.new
      provider.define_singleton_method(:get_account_balances) { |**| { balances: [] } }
      provider.define_singleton_method(:get_account_transactions) do |**params|
        requests << params
        page = requests.size
        more = pages.nil? || page < pages
        { transactions: [ test_case.send(:booked_tx, "p#{page}", (page % 300).days.ago.to_date.iso8601) ], continuation_key: (more ? "k#{page}" : nil) }
      end
      importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: provider)
      importer.stubs(:fetch_session_data).returns(accounts: [])
      importer
    end

    def link!
      account = Account.create!(
        family: @family,
        name: "EB linked",
        balance: 0,
        currency: "EUR",
        accountable: Depository.create!
      )
      AccountProvider.create!(account: account, provider: @enable_banking_account)
      @enable_banking_account.reload
    end

    def booked_tx(id, date)
      {
        transaction_id: id,
        entry_reference: "ref_#{id}",
        booking_date: date,
        transaction_amount: { amount: "10.00", currency: "EUR" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    end
end
