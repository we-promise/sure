require "test_helper"

class EnableBankingItem::ImporterEarlyFetchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = EnableBankingItem.create!(
      family: @family, name: "Test EB", country_code: "FR", application_id: "app",
      client_certificate: "cert", session_id: "sess", session_expires_at: 1.day.from_now
    )
    @eba = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Compte", uid: "early_uid", account_id: "early-uuid", currency: "EUR"
    )
    @requests = []
    Setting.stubs(:syncs_include_pending).returns(false)
    @item.stubs(:upsert_enable_banking_snapshot!)
  end

  test "complete_authorization requests a full-history fetch" do
    provider = mock()
    provider.stubs(:create_session).returns(session_id: "new_sess", accounts: [])
    @item.stubs(:enable_banking_provider).returns(provider)

    freeze_time do
      @item.complete_authorization(code: "code")

      assert_equal Time.current, @item.reload.full_history_fetch_requested_at
    end
  end

  test "complete_authorization writes the request only after the session's accounts exist" do
    provider = mock()
    provider.stubs(:create_session).returns(
      session_id: "new_sess", accounts: [ { uid: "session_uid", account_id: { iban: "FR7630006000011234567890189" }, currency: "EUR" } ] # pipelock:ignore IBAN
    )
    @item.stubs(:enable_banking_provider).returns(provider)

    @item.complete_authorization(code: "code")

    account = @item.enable_banking_accounts.find_by!(uid: "session_uid")
    assert_operator @item.reload.full_history_fetch_requested_at, :>=, account.created_at,
                    "a sync can see the request before the session's accounts are imported"
  end

  test "an account import that fails part-way leaves no account without the request" do
    provider = mock()
    provider.stubs(:create_session).returns(
      session_id: "new_sess",
      accounts: [ { uid: "ok_uid", currency: "EUR" }, { uid: "failing_uid", currency: "EUR" } ]
    )
    @item.stubs(:enable_banking_provider).returns(provider)
    # The second account fails validation.
    EnableBankingAccount.any_instance.stubs(:build_account_name).returns("Ok").then.returns(nil)

    assert_raises(ActiveRecord::RecordInvalid) { @item.complete_authorization(code: "code") }

    assert_nil @item.enable_banking_accounts.find_by(uid: "ok_uid"),
               "an imported account was committed without a full-history request"
    assert_nil @item.reload.full_history_fetch_requested_at
  end

  test "the sync after an authorization fetches unlinked accounts once with strategy=longest" do
    request_full_history!

    build_importer(transactions: [ tx("old", "2019-01-01"), tx("new", 2.days.ago.to_date.iso8601) ]).import

    assert_equal 1, @requests.size
    assert_equal "longest", @requests.first[:strategy]
    assert_nil @requests.first[:date_from]
    assert_equal 2, @eba.reload.raw_transactions_payload.size
    assert_not_nil @eba.early_fetched_at
    assert_nil @item.reload.full_history_fetch_requested_at

    build_importer.import
    assert_equal 1, @requests.size, "an unlinked account is fetched again on a routine sync"
  end

  test "a routine sync does not fetch unlinked accounts" do
    Sync.create!(syncable: @item, status: "completed", completed_at: 60.days.ago, created_at: 60.days.ago)

    build_importer(transactions: [ tx("old", "2019-01-01") ]).import

    assert_empty @requests
    assert_nil @eba.reload.raw_transactions_payload
  end

  test "a failing unlinked account is retried only while the request is fresh, and never fails the sync" do
    request_full_history!
    calls = 0
    provider = mock()
    provider.stubs(:get_account_balances).returns(balances: [])
    provider.stubs(:get_account_transactions).with { |_| calls += 1; true }
            .raises(Provider::EnableBanking::EnableBankingError.new("forbidden", :forbidden))
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    results = Array.new(2) { importer.import }
    assert_equal 2, calls
    assert results.all? { |result| result[:success] }, "a failed early fetch fails the sync"
    assert_not_nil @item.reload.full_history_fetch_requested_at

    warnings = []
    Rails.logger.stubs(:warn).with { |msg| warnings << msg.to_s; true }
    travel EnableBankingItem::Importer::FULL_HISTORY_REQUEST_WINDOW + 1.minute do
      importer.import
    end
    assert_equal 2, calls, "an expired request is still retried"
    assert warnings.any? { |msg| msg.include?("Dropping the full-history request") }, "no log line for the dropped request"
    assert_nil @item.reload.full_history_fetch_requested_at
  end

  test "an authorization completed mid-sync keeps its full-history request" do
    request_full_history!(5.minutes.ago)
    item = @item
    requests = @requests
    provider = Object.new
    provider.define_singleton_method(:get_account_balances) { |**| { balances: [] } }
    provider.define_singleton_method(:get_account_transactions) do |**p|
      requests << p
      raise Provider::EnableBanking::EnableBankingError.new("timeout", :timeout) if p[:account_id] == "new-uuid"

      unless EnableBankingAccount.exists?(uid: "new_uid")
        # The OAuth callback of a new authorization commits while this sync runs.
        EnableBankingAccount.create!(enable_banking_item: item, name: "New", uid: "new_uid", account_id: "new-uuid", currency: "EUR")
        EnableBankingItem.where(id: item.id).update_all(session_id: "new_sess", full_history_fetch_requested_at: Time.current)
      end
      { transactions: [] }
    end
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])
    importer.import

    assert_equal %w[early-uuid new-uuid], @requests.map { |p| p[:account_id] }
    assert_not_nil EnableBankingItem.find(item.id).full_history_fetch_requested_at,
                   "new authorization's request was consumed by the old sync"
  end

  test "an authorization completed after the early fetch is handled in the same sync" do
    link!
    @eba.update!(raw_transactions_payload: [ tx("stored", 3.days.ago.to_date.iso8601) ])
    item = @item
    requests = @requests
    provider = Object.new
    provider.define_singleton_method(:get_account_balances) { |**| { balances: [] } }
    provider.define_singleton_method(:get_account_transactions) do |**p|
      requests << p
      if p[:account_id] == "early-uuid" && !EnableBankingAccount.exists?(uid: "new_uid")
        # The OAuth callback commits while the linked account is fetched; its
        # sync_later reuses this sync.
        EnableBankingAccount.create!(enable_banking_item: item, name: "New", uid: "new_uid", account_id: "new-uuid", currency: "EUR")
        EnableBankingItem.where(id: item.id).update_all(full_history_fetch_requested_at: Time.current)
      end
      { transactions: [] }
    end
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])
    importer.import

    new_account_request = @requests.find { |p| p[:account_id] == "new-uuid" }
    assert new_account_request, "the new authorization's account waited for the next sync"
    assert_equal "longest", new_account_request[:strategy]
    assert_nil @item.reload.full_history_fetch_requested_at
  end

  test "a truncated early fetch is counted as truncated" do
    request_full_history!
    provider = Object.new
    provider.define_singleton_method(:get_account_balances) { |**| { balances: [] } }
    provider.define_singleton_method(:get_account_transactions) do |**|
      { transactions: [ { transaction_id: "a", booking_date: "2020-01-01", status: "BOOK",
                          transaction_amount: { amount: "1.00", currency: "EUR" }, credit_debit_indicator: "DBIT" } ],
        continuation_key: "same" }
    end
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    result = importer.import

    assert_equal 1, result[:transactions_truncated]
    assert_equal 1, @eba.reload.raw_transactions_payload.size
  end

  test "a failed early fetch stores only sanitized error fields in the debug log" do
    request_full_history!
    errors = [
      Provider::EnableBanking::EnableBankingError.new("BODY-MARKER raw response", :validation_error,
                                                      response_data: { message: "Invalid account" }),
      StandardError.new("OTHER-MARKER raw response")
    ]
    provider = Object.new
    provider.define_singleton_method(:get_account_balances) { |**| { balances: [] } }
    provider.define_singleton_method(:get_account_transactions) { |**| raise errors.shift }
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    2.times { importer.import }

    provider_entry, other_entry = DebugLogEntry.where(provider_key: "enable_banking").order(:created_at).last(2)
    assert_not_includes provider_entry.metadata.to_json, "BODY-MARKER"
    assert_equal "Invalid account", provider_entry.metadata.dig("provider_error", "message")
    assert_not_includes other_entry.metadata.to_json, "OTHER-MARKER"
    assert_equal "StandardError", other_entry.metadata["error_class"]
  end

  test "rows of an early fetch are never stored without early_fetched_at" do
    request_full_history!
    EnableBankingAccount.any_instance.stubs(:update_columns).raises(ActiveRecord::StatementInvalid.new("write failed"))

    build_importer(transactions: [ tx("a", "2020-01-01") ]).import

    assert_nil @eba.reload.raw_transactions_payload, "rows stored that the purge can never delete"
    assert_not_nil @item.reload.full_history_fetch_requested_at
  end

  test "the early fetch runs before the linked accounts are fetched" do
    linked = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Linked", uid: "linked_uid", account_id: "linked-uuid", currency: "EUR",
      raw_transactions_payload: [ tx("stored", 3.days.ago.to_date.iso8601) ]
    )
    link!(linked)
    request_full_history!

    build_importer.import

    assert_equal %w[early-uuid linked-uuid], @requests.map { |p| p[:account_id] }
    assert_equal "longest", @requests.first[:strategy]
  end

  test "a failed early fetch is captured as a debug log entry" do
    request_full_history!
    provider = mock()
    provider.stubs(:get_account_balances).returns(balances: [])
    provider.stubs(:get_account_transactions)
            .raises(Provider::EnableBanking::EnableBankingError.new("forbidden", :forbidden))
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    assert_difference -> { DebugLogEntry.where(provider_key: "enable_banking", category: "provider_sync_error").count }, 1 do
      importer.import
    end

    entry = DebugLogEntry.last
    assert_equal @family, entry.family
    assert_equal "early_uid", entry.metadata["uid"]
    assert_equal "forbidden", entry.metadata.dig("provider_error", "error_type")
  end

  test "a failing purge is captured in provider diagnostics and does not raise" do
    @eba.update_columns(raw_transactions_payload: [ tx("a", "2020-01-01") ], early_fetched_at: 10.days.ago)
    ActiveRecord::Relation.any_instance.stubs(:update_all).raises(ActiveRecord::StatementInvalid, "lock timeout")

    assert_difference -> { DebugLogEntry.where(provider_key: "enable_banking", category: "provider_sync_error").count }, 1 do
      assert_nothing_raised { build_importer.purge_stale_unlinked_transactions }
    end

    entry = DebugLogEntry.where(provider_key: "enable_banking").order(:created_at).last
    assert_equal @family, entry.family
    assert_equal "EnableBankingItem::Importer", entry.source
    assert_equal @item.id, entry.metadata["enable_banking_item_id"]
    assert_equal "ActiveRecord::StatementInvalid", entry.metadata["error_class"]
    assert_not_nil @eba.reload.raw_transactions_payload
  end

  test "a re-authorization does not refetch accounts that already have rows" do
    Sync.create!(syncable: @item, status: "completed", completed_at: 1.day.ago, created_at: 1.day.ago)
    link!
    @eba.update!(raw_transactions_payload: [ tx("stored", 3.days.ago.to_date.iso8601) ])
    # Unlinked by the user, rows kept.
    unlinked = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Unlinked", uid: "unlinked_uid", account_id: "unlinked-uuid", currency: "EUR",
      raw_transactions_payload: [ tx("kept", 30.days.ago.to_date.iso8601) ]
    )
    request_full_history!

    build_importer(transactions: [ tx("old", "2019-01-01"), tx("stored", 3.days.ago.to_date.iso8601) ]).import

    assert_equal 1, @requests.size, "an account with stored rows was fetched again"
    assert_nil @requests.first[:strategy], "a linked account got a longest fetch after a re-authorization"
    assert_equal %w[stored], @eba.reload.raw_transactions_payload.map { |row| row["transaction_id"] }
    assert_equal %w[kept], unlinked.reload.raw_transactions_payload.map { |row| row["transaction_id"] }
    assert_nil @item.reload.full_history_fetch_requested_at
  end

  test "a re-authorization does not fetch an account the user ignored" do
    @eba.ignore!
    request_full_history!

    build_importer(transactions: [ tx("old", "2019-01-01") ]).import

    assert_empty @requests, "an ignored account was fetched"
    assert_nil @eba.reload.raw_transactions_payload
    assert_nil @eba.early_fetched_at
    assert_nil @item.reload.full_history_fetch_requested_at
  end

  test "a failed linked fetch does not keep the request" do
    link!
    @eba.update!(raw_transactions_payload: [ tx("a", 3.days.ago.to_date.iso8601) ])
    request_full_history!
    provider = mock()
    provider.stubs(:get_account_balances).returns(balances: [])
    provider.stubs(:get_account_transactions)
            .raises(Provider::EnableBanking::EnableBankingError.new("Request timeout", :timeout))
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
    importer.stubs(:fetch_session_data).returns(accounts: [])

    importer.import

    assert_nil @item.reload.full_history_fetch_requested_at
  end

  test "a request set after the in-memory item was loaded is still honoured" do
    EnableBankingItem.where(id: @item.id).update_all(full_history_fetch_requested_at: Time.current)

    build_importer.import

    assert_equal "longest", @requests.first[:strategy]
  end

  test "the purge does not delete a payload fetched in the same sync" do
    # Early-fetched after an earlier authorization and never linked.
    @eba.update_columns(raw_transactions_payload: [ tx("a", "2020-01-01") ], early_fetched_at: 10.days.ago)
    request_full_history!

    sync_import(build_importer(transactions: [ tx("a", "2020-01-01") ]))

    assert_equal "longest", @requests.first[:strategy]
    assert_not_nil @eba.reload.raw_transactions_payload, "payload fetched seconds ago was purged"
    assert_in_delta Time.current, @eba.early_fetched_at, 1.minute
  end

  test "early-fetched rows of an account that stays unlinked are deleted after the retention period" do
    @eba.update_columns(raw_transactions_payload: [ tx("a", 9.days.ago.to_date.iso8601) ], early_fetched_at: 8.days.ago)
    recent = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Recent", uid: "recent_uid", account_id: "recent-uuid", currency: "EUR",
      raw_transactions_payload: [ tx("b", 2.days.ago.to_date.iso8601) ], early_fetched_at: 2.days.ago
    )
    linked = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Linked", uid: "linked_uid", account_id: "linked-uuid", currency: "EUR",
      raw_transactions_payload: [ tx("c", 20.days.ago.to_date.iso8601) ], early_fetched_at: 30.days.ago
    )
    link!(linked)
    # Unlinked by the user, so its rows were not stored by an early fetch.
    unlinked = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Unlinked", uid: "unlinked_uid", account_id: "unlinked-uuid", currency: "EUR",
      raw_transactions_payload: [ tx("d", 20.days.ago.to_date.iso8601) ]
    )
    unlinked.update_columns(updated_at: 30.days.ago)

    sync_import(build_importer)

    assert_nil @eba.reload.raw_transactions_payload
    assert_nil @eba.early_fetched_at
    assert_equal 1, recent.reload.raw_transactions_payload.size
    assert_equal 1, linked.reload.raw_transactions_payload.size
    assert_equal 1, unlinked.reload.raw_transactions_payload.size
  end

  test "an early-fetched account that was linked keeps its rows after it is unlinked" do
    @eba.update_columns(raw_transactions_payload: [ tx("a", 20.days.ago.to_date.iso8601) ], early_fetched_at: 1.day.ago)
    account = link!
    EnableBankingAccount::Transactions::Processor.new(@eba).process
    assert_equal 1, account.entries.count
    assert_nil @eba.reload.early_fetched_at

    AccountProvider.where(provider: @eba).destroy_all
    travel EnableBankingItem::Importer::UNLINKED_TRANSACTIONS_RETENTION + 1.day do
      sync_import(build_importer)
    end

    assert_equal 1, @eba.reload.raw_transactions_payload.size, "rows of a once-linked account were purged"

    # Relinking is incremental, as before.
    AccountProvider.create!(account: account, provider: @eba.reload)
    sync_import(build_importer)
    assert_nil @requests.last[:strategy]
  end

  test "rows before a sync_start_date set mid-sync are not imported" do
    account = link!
    @eba.update!(raw_transactions_payload: [ tx("old", 2.years.ago.to_date.iso8601), tx("new", 5.days.ago.to_date.iso8601) ])
    stale_item = EnableBankingItem.find(@item.id)
    stale_item.enable_banking_accounts.to_a # loaded at sync start
    EnableBankingItem.find(@item.id).update!(sync_start_date: 30.days.ago.to_date) # setup modal submitted

    stale_item.process_accounts

    assert_equal 1, account.entries.count, "rows before the chosen start date were imported"
  end


  test "an account linked but not yet processed keeps its early rows when unlinked" do
    @item.update!(session_expires_at: 30.days.from_now)
    request_full_history!
    sync_import(build_importer(transactions: [ tx("old", "2019-01-01"), tx("new", 2.days.ago.to_date.iso8601) ]))
    assert_not_nil @eba.reload.early_fetched_at

    account = link!
    # Syncs after the link fail before process_accounts (another account's
    # fetch fails), but the import itself still runs.
    travel 3.days do
      sync_import(build_importer)
    end

    travel 8.days do
      AccountProvider.where(provider: @eba).destroy_all # user unlinks to retry
      sync_import(build_importer)
    end

    assert_equal 2, @eba.reload.raw_transactions_payload.to_a.size,
                 "full history of an account the user linked was purged after an unlink"
    assert account.persisted?
  end


  test "an account linked then deleted before any processing is still purged" do
    @item.update!(session_expires_at: 30.days.from_now)
    request_full_history!
    sync_import(build_importer(transactions: [ tx("old", "2019-01-01") ]))
    account = link!
    account.update_columns(status: "pending_deletion")
    travel 1.hour do
      sync_import(build_importer)
    end
    account.destroy!
    travel 8.days do
      sync_import(build_importer)
    end
    assert_nil @eba.reload.raw_transactions_payload, "rows of a deleted, never-processed account were kept"
  end

  private
    # What the syncer does: purge stale early rows, then import.
    def sync_import(importer)
      importer.purge_stale_unlinked_transactions
      importer.import
    end

    def build_importer(transactions: [])
      requests = @requests
      provider = mock()
      provider.stubs(:get_account_balances).returns(balances: [])
      provider.stubs(:get_account_transactions).with { |params| requests << params; true }.returns(transactions: transactions)
      importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)
      importer.stubs(:fetch_session_data).returns(accounts: [])
      importer
    end

    def request_full_history!(at = Time.current)
      @item.update!(full_history_fetch_requested_at: at)
    end

    def link!(enable_banking_account = @eba)
      account = Account.create!(family: @family, name: "Linked", balance: 0, currency: "EUR", accountable: Depository.create!)
      AccountProvider.create!(account: account, provider: enable_banking_account)
      enable_banking_account.reload
      account
    end

    def tx(id, date, amount: "10.00")
      { transaction_id: id, entry_reference: "ref_#{id}", booking_date: date,
        transaction_amount: { amount: amount, currency: "EUR" }, credit_debit_indicator: "DBIT", status: "BOOK" }
    end
end
