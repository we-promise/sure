require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Wise::InterbalanceTransfersTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Linker = Provider::AccountData::Wise::InterbalanceTransfers

  class Client
    attr_accessor :activity, :activity_response, :before_read
    attr_reader :reads

    def initialize(balances, activity)
      @balances, @activity, @reads = balances, activity, []
    end

    def get_balances_page(_profile, type:)
      read(:balances)
      { items: @balances.select { |row| row[:type] == type }, next_cursor: nil }
    end

    def get_borderless_accounts_page(_profile)
      read(:borderless)
      { items: [], next_cursor: nil }
    end

    def get_balance_statement_page(*)
      read(:statements)
      { items: [], next_cursor: nil }
    end

    def get_activities_page(_profile, cursor:)
      read(:activities)
      { items: activity_response ? activity_response.call : [ activity ], next_cursor: nil }
    end

    private
      def read(operation)
        before_read&.call
        @reads << operation
      end
  end

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    clear_enqueued_jobs
    @family = families(:dylan_family)
    @timestamps = @family.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Registry.stubs(:fetch).with("wise").returns(Provider::AccountData::Wise)
  end

  teardown do
    clear_enqueued_jobs
    Family.where(id: @family.id).update_all(@timestamps)
    travel_back
  end

  test "real publication finalizes one confirmed pair without changing either financial posting" do
    with_sources do |connection, externals, accounts, client|
      before_join = nil
      snapshot = -> { financial_snapshot(accounts) }
      callback = ->(_transfer) { before_join = snapshot.call }
      Transfer.set_callback(:create, :before, callback)
      sync = connection.syncs.create!
      begin
        assert_difference "Transfer.count", 1 do
          run_sync(connection, sync)
        end
      ensure
        Transfer.skip_callback(:create, :before, callback)
      end

      transfer = pair_for(accounts)
      assert transfer.confirmed?
      assert_equal accounts.last.id, transfer.to_account.id
      assert_equal accounts.first.id, transfer.from_account.id
      assert_equal before_join, financial_snapshot(accounts)
      assert_equal [ "wise_interbalance_movement-1_inflow", "wise_interbalance_movement-1_outflow" ], entries(accounts).pluck(:external_id).sort
      assert_equal 2, SourceRecord.where(external_account: externals).count
      assert_equal 2, EntrySource.where(account: accounts).count
      reads = client.reads.dup
      assert_no_difference "Transfer.count" do
        run_sync(connection, sync.reload)
      end
      assert_equal reads, client.reads
      assert_equal transfer.id, pair_for(accounts).id
      assert_equal before_join, financial_snapshot(accounts)
    end
  end

  test "withdrawals use actual direction while retaining the original JAR and STANDARD external IDs" do
    with_sources do |connection, _externals, accounts, client|
      client.activity = activity(title: "From <strong>Trip</strong>")
      run_sync(connection, connection.syncs.create!)

      transfer = pair_for(accounts)
      assert transfer.confirmed?
      assert_equal accounts.first.id, transfer.to_account.id
      assert_equal accounts.last.id, transfer.from_account.id
      assert_equal "wise_interbalance_movement-1_inflow", transfer.outflow_transaction.entry.external_id
      assert_equal "wise_interbalance_movement-1_outflow", transfer.inflow_transaction.entry.external_id
    end
  end

  test "an older applied counterpart links when the other leg arrives in a later Sync" do
    with_sources do |connection, externals, accounts, client|
      ordered = externals.sort_by(&:id)
      calls = 0
      client.activity_response = lambda do
        calls += 1
        raise Provider::Wise::WiseError.new("private failure", :request_failed) if calls == 2
        [ activity ]
      end
      first = connection.syncs.create!
      assert_raises(Provider::AccountData::Error) { run_sync(connection, first) }
      original = SourceRecord.where(external_account: externals).sole
      assert_equal ordered.first.id, original.external_account_id
      original_entry = original.entry_source.entry_id
      original_batch = original.ingestion_batch_id
      assert_empty Transfer.where(inflow_transaction_id: entries(accounts).pluck(:entryable_id))

      travel 1.minute
      # The previously failed account has no completed transaction checkpoint and
      # is scheduled first. The already captured counterpart need not be returned.
      calls = 0
      client.activity_response = -> { calls += 1; calls == 1 ? [ activity ] : [] }
      second = connection.syncs.create!
      run_sync(connection, second)

      assert pair_for(accounts).confirmed?
      assert_equal original_entry, original.reload.entry_source.entry_id
      assert_equal original_batch, original.ingestion_batch_id
      assert_equal [ first.id, second.id ].sort, SourceRecord.where(external_account: externals).joins(:ingestion_batch).pluck("ingestion_batches.sync_id").sort
    end
  end

  test "an unlinked STANDARD or duplicate-name JAR makes profile routing ambiguous" do
    [ { type: "STANDARD", name: "Other balance" }, { type: "SAVINGS", name: "Trip" } ].each do |extra|
      with_sources(extra: extra) do |connection, _externals, accounts, _client|
        assert_no_difference "Transfer.count" do
          run_sync(connection, connection.syncs.create!)
        end
        assert_equal 2, entries(accounts).count
      end
    end
  end

  test "an account deferral schedules the original job before historical pair review and links after continuation" do
    with_sources do |connection, externals, accounts, client|
      ProviderConnection.any_instance.stubs(:perform_post_sync)
      ProviderConnection.any_instance.stubs(:broadcast_sync_complete)
      calls = 0
      client.activity_response = lambda do
        calls += 1
        raise Provider::AccountData::DeferredPage.new(resume_at: 15.seconds.from_now) if calls == 2
        [ activity ]
      end
      sync = connection.syncs.create!
      forbid_review = ->(**) { flunk "A deferred account must resume before pair finalization" }

      Linker.stub(:new, forbid_review) do
        assert_enqueued_with(job: SyncJob, args: [ sync ]) { SyncJob.perform_now(sync) }
      end

      assert sync.reload.pending?, sync.error
      assert_equal 1, sync.provider_attempt
      assert_equal 1, SourceRecord.where(external_account: externals).count
      assert_empty Transfer.where(inflow_transaction_id: entries(accounts).pluck(:entryable_id))
      original_entry = entries(accounts).sole.id
      travel 16.seconds
      assert_difference("Transfer.count", 1) { SyncJob.perform_now(sync.reload) }

      assert sync.reload.completed?, sync.error
      assert_equal 3, calls
      assert_includes entries(accounts).pluck(:id), original_entry
      assert pair_for(accounts).confirmed?
    end
  end

  test "equal economics cannot pair different resource IDs or conflicting representations of one event" do
    %i[resource activity].each do |conflict|
      with_sources do |connection, _externals, accounts, client|
        calls = 0
        client.activity_response = lambda do
          calls += 1
          [ if calls == 1
              activity
            elsif conflict == :resource
              activity(resource: { "type" => "BALANCE_TRANSACTION", "id" => "different-movement" })
            else
              activity(id: "different-event")
            end ]
        end
        assert_no_difference "Transfer.count" do
          run_sync(connection, connection.syncs.create!)
        end
        assert_equal 2, entries(accounts).count
      end
    end
  end

  test "pending or missing provider completion evidence never confirms a pair" do
    [ "PENDING", nil ].each do |status|
      with_sources do |connection, _externals, accounts, client|
        client.activity = activity(status: status)
        assert_no_difference "Transfer.count" do
          run_sync(connection, connection.syncs.create!)
        end
        assert_equal 2, entries(accounts).count
      end
    end
  end

  test "protections reconciliation and economic edits prevent automatic linking without reverting changes" do
    [ { user_modified: true, name: "My movement", notes: "My note" }, { import_locked: true }, { excluded: true },
      { reconciled_at: Time.utc(2026, 9, 15) }, { amount: -42 } ].each do |changes|
      with_sources do |connection, _externals, accounts, _client|
        sync = connection.syncs.create!
        publish_without_linking(connection, sync)
        accounts.last.entries.sole.update_columns(changes)
        before = financial_snapshot(accounts)

        assert_no_difference "Transfer.count" do
          run_sync(connection, sync.reload)
        end

        assert_equal before, financial_snapshot(accounts)
      end
    end
  end

  test "an existing exact pending transfer and user rejected pair retain their decisions" do
    %i[pending rejected].each do |decision|
      with_sources do |connection, _externals, accounts, _client|
        sync = connection.syncs.create!
        publish_without_linking(connection, sync)
        transfer = Transfer.create!(inflow_transaction: accounts.last.entries.sole.transaction,
          outflow_transaction: accounts.first.entries.sole.transaction, status: "pending")
        transfer.reject! if decision == :rejected
        before = financial_snapshot(accounts)

        assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
          run_sync(connection, sync.reload)
        end

        assert_equal before, financial_snapshot(accounts)
        assert transfer.reload.pending? if decision == :pending
      end
    end
  end

  test "competing transfers and fee-associated postings are not reassigned" do
    %i[competing fee].each do |association|
      with_sources do |connection, _externals, accounts, _client|
        sync = connection.syncs.create!
        publish_without_linking(connection, sync)
        manual = accounts.last.entries.create!(name: "Manual counterpart", date: Date.current, amount: -100, currency: "EUR", entryable: Transaction.new)
        outflow = if association == :fee
          accounts.first.entries.create!(name: "Manual outflow", date: Date.current, amount: 100, currency: "EUR", entryable: Transaction.new)
        else
          accounts.first.entries.sole
        end
        transfer = Transfer.create!(inflow_transaction: manual.transaction,
          outflow_transaction: outflow.transaction, status: "confirmed")
        accounts.last.entries.where(source: "wise").sole.transaction.update!(transfer_id: transfer.id) if association == :fee
        before = financial_snapshot(accounts)

        assert_no_difference "Transfer.count" do
          run_sync(connection, sync.reload)
        end

        assert_equal before, financial_snapshot(accounts)
        assert_equal manual.transaction.id, transfer.reload.inflow_transaction_id
      end
    end
  end

  test "an unselected current source cannot claim an older authoritative posting" do
    with_sources do |connection, externals, accounts, client|
      sync = connection.syncs.create!
      publish_without_linking(connection, sync)
      other = create_provider_connection
      begin
        other_external = create_external_account(other, currency: "EUR")
        other_link = AccountProvider.create!(account: accounts.last, external_account: other_external)
        Account::SourcePolicy.select!(account: accounts.last, account_provider: other_link, resource: "transactions")
        before = financial_snapshot(accounts)
        travel 1.minute

        assert_no_difference "Transfer.count" do
          run_sync(connection, connection.syncs.create!)
        end

        assert_equal before, financial_snapshot(accounts)
        assert_equal other_link.id, Account::SourcePolicy.active.find_by!(account: accounts.last, resource: "transactions").account_provider_id
        assert_equal 2, SourceRecord.where(external_account: externals).count
      ensure
        Account::SourcePolicy.where(account_provider_id: other_link&.id).delete_all
        other_link&.destroy!
        other&.external_accounts&.delete_all
        other&.delete
      end
    end
  end

  test "detached posting and malformed native request proof cannot manufacture a transfer" do
    %i[posting grant].each do |missing|
      with_sources do |connection, externals, accounts, _client|
        sync = connection.syncs.create!
        publish_without_linking(connection, sync)
        observation = SourceRecord.find_by!(external_account: externals.first)
        if missing == :posting
          observation.entry_source.delete
          assert_no_difference("Transfer.count") { run_sync(connection, sync.reload) }
        else
          batch = observation.ingestion_batch
          page = Ingestion::Codec.load(batch.payload)
          altered = Provider::AccountData::Page.new(records: page.records, complete: page.complete?, mode: page.mode,
            coverage: page.coverage, evidence: page.evidence.except(Provider::AccountData::RequestGrant::EVIDENCE_KEY))
          batch.update_columns(payload: Ingestion::Codec.dump(altered))
          assert_raises(Provider::AccountData::StaleWriter) { run_sync(connection, sync.reload) }
        end
        assert_equal 2, entries(accounts).count
      end
    end
  end

  test "transfer insertion failure rolls back only finalization and replay keeps original entries" do
    with_sources do |connection, _externals, accounts, client|
      callback = ->(_transfer) { raise ActiveRecord::StatementInvalid, "interrupted join" }
      Transfer.set_callback(:create, :before, callback)
      sync = connection.syncs.create!
      begin
        assert_no_difference "Transfer.count" do
          assert_raises(Provider::AccountData::Error) { run_sync(connection, sync) }
        end
      ensure
        Transfer.skip_callback(:create, :before, callback)
      end
      before = financial_snapshot(accounts)
      reads = client.reads.dup

      assert_difference("Transfer.count", 1) { run_sync(connection, sync.reload) }

      assert_equal before, financial_snapshot(accounts)
      assert_equal reads, client.reads
    end
  end

  test "pair scans and original encrypted batch reads are bounded" do
    [ :MAX_OBSERVATIONS, :MAX_BATCH_BYTES ].each do |limit|
      with_sources do |connection, _externals, accounts, client|
        sync = connection.syncs.create!
        publish_without_linking(connection, sync)
        before = financial_snapshot(accounts)
        reads = client.reads.dup
        previous = Linker.const_get(limit)
        begin
          Linker.send(:remove_const, limit)
          Linker.const_set(limit, 1)
          assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync.reload) }
        ensure
          Linker.send(:remove_const, limit)
          Linker.const_set(limit, previous)
        end
        assert_equal before, financial_snapshot(accounts)
        assert_equal reads, client.reads
      end
    end
  end

  private
    def activity(**changes)
      { "id" => "activity-1", "type" => "INTERBALANCE", "resource" => { "type" => "BALANCE_TRANSACTION", "id" => "movement-1" },
        "status" => "COMPLETED", "title" => "To <strong>Trip</strong>", "primaryAmount" => "100 EUR",
        "createdOn" => "2026-09-12T12:00:00Z" }.merge(changes.stringify_keys)
    end

    def run_sync(connection, sync)
      Provider::AccountData::Syncer.new(connection).perform_sync(sync)
    end

    def publish_without_linking(connection, sync)
      Linker.any_instance.stubs(:perform)
      run_sync(connection, sync)
    ensure
      Linker.any_instance.unstub(:perform)
    end

    def entries(accounts)
      Entry.where(account_id: accounts.map(&:id))
    end

    def pair_for(accounts)
      Transfer.where(inflow_transaction_id: entries(accounts).pluck(:entryable_id)).sole
    end

    def financial_snapshot(accounts)
      rows = entries(accounts).order(:id)
      [ rows.map(&:attributes), Transaction.where(id: rows.pluck(:entryable_id)).order(:id).map(&:attributes) ]
    end

    def with_sources(extra: nil)
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "wise", credentials: { "token" => "private-token" },
          settings: { "profile_id" => "profile" }, sync_start_date: Date.new(2026, 9, 1))
        definitions = [ { type: "STANDARD", name: "Wise EUR" }, { type: "SAVINGS", name: "Trip" } ]
        definitions << extra if extra
        accounts = []
        externals = definitions.each_with_index.map do |definition, index|
          external = create_external_account(connection, external_id: "balance-#{index}", name: definition[:name],
            currency: "EUR", account_type: definition[:type])
          if index < 2
            account = connection.family.accounts.create!(name: definition[:name], currency: "EUR", balance: 100, accountable: Depository.new)
            accounts << account
            link = AccountProvider.create!(account: account, external_account: external)
            Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[transactions balances])
          end
          external
        end
        balances = definitions.each_with_index.map { |definition, index| definition.merge(id: externals[index].external_id,
          amount: { value: "100", currency: "EUR" }, totalWorth: { value: "100" }) }
        client = Client.new(balances, activity)
        client.before_read = -> { assert_equal 0, ProviderConnection.connection.open_transactions }
        Provider::Wise.stubs(:new).returns(client)
        yield connection, externals, accounts, client
      ensure
        if connection
          ProviderConnection.where(id: connection.id).update_all(lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
          observations = SourceRecord.where(external_account: connection.external_accounts)
          EntrySource.where(source_record: observations).delete_all
          observations.delete_all
          connection.provider_sync_checkpoints.delete_all
          connection.ingestion_batches.delete_all
          accounts.each do |account|
            Account::SourcePolicy.where(account: account).delete_all
            AccountProvider.where(account: account).delete_all
            account.reload.destroy!
          end
          connection.external_accounts.delete_all
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all
          connection.delete
        end
      end
    end
end
