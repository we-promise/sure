require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Wise::StatementBarrierTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Barrier = Provider::AccountData::Wise::StatementBarrier

  class Client
    attr_accessor :statement, :before_read
    attr_reader :requests

    def initialize(ids)
      @ids, @requests = ids, []
      @statement = ->(_id) { raise Provider::Wise::WiseError.new("private denied body", :access_forbidden) }
    end

    def get_balances_page(_profile, type:)
      read([ :inventory, type ])
      { items: type == "STANDARD" ? @ids.map { |id| { id: id, type: "STANDARD", amount: { value: "100", currency: "EUR" } } } : [], next_cursor: nil }
    end

    def get_borderless_accounts_page(_profile)
      read([ :borderless ])
      { items: [], next_cursor: nil }
    end

    def get_balance_statement_page(_profile, id, currency:, interval_start:, interval_end:)
      read([ :statement, id, currency, interval_start, interval_end ])
      { items: statement.call(id), next_cursor: nil }
    end

    def get_transfers_page(_profile, cursor:)
      read([ :transfers, cursor ])
      { items: [], next_cursor: nil }
    end

    def get_activities_page(_profile, cursor:)
      read([ :activities, cursor ])
      { items: [], next_cursor: nil }
    end

    private
      def read(request)
        before_read&.call
        @requests << request
      end
  end

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    clear_enqueued_jobs
    @family = families(:dylan_family)
    @timestamps = @family.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Account.any_instance.stubs(:sync_later)
    ProviderConnection.any_instance.stubs(:perform_post_sync)
    ProviderConnection.any_instance.stubs(:broadcast_sync_complete)
    Provider::AccountData::Registry.stubs(:fetch).with("wise").returns(Provider::AccountData::Wise)
  end

  teardown do
    clear_enqueued_jobs
    Family.where(id: @family.id).update_all(@timestamps)
    travel_back
  end

  test "all denied profile probes permit fallback without advancing any historical coverage" do
    with_sources do |connection, externals, accounts, client|
      prior = Time.utc(2026, 9, 1)
      connection.provider_sync_checkpoints.create!(external_account: externals.first, stream: "transactions",
        scope_key: "account:#{externals.first.id}", covered_through: prior)
      sync = connection.syncs.create!

      run_sync(connection, sync)

      assert_equal 2, requests(client, :statement).size
      assert_equal 2, requests(client, :transfers).size
      assert_equal 2, requests(client, :activities).size
      assert_equal prior, checkpoint(connection, externals.first).covered_through
      assert_nil checkpoint(connection, externals.last).covered_through
      externals.each do |external|
        last = checkpoint(connection, external).ingestion_batch
        assert last.applied?
        assert_equal false, last.coverage["history_complete"]
        assert_equal true, Ingestion::Codec.load(last.payload).evidence.dig("wise_statement_barrier", "fallback_authorized")
      end
      assert accounts.all? { |account| account.entries.empty? }
      assert_empty connection.provider_sync_checkpoints.where(stream: Provider::AccountData::Wise::StatementHistory::STREAM)
      assert_equal 2, probe_batches(connection).count
      assert probe_batches(connection).all?(&:captured?)
      assert connection.ingestion_batches.where("scope_key LIKE 'wise_statement_manifest:%'").all? { |batch| batch.source_binding["account_id"].present? }
      assert_not_includes probe_batches(connection).map(&:payload).inspect, "private denied body"
    end
  end

  test "successful empty statement vetoes profile fallback while the successful account completes" do
    with_sources do |connection, externals, _accounts, client|
      client.statement = ->(id) { id == externals.first.external_id ? [] : deny! }

      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, connection.syncs.create!) }

      assert_equal 2, requests(client, :statement).size
      assert_empty requests(client, :transfers)
      assert_equal Time.current, checkpoint(connection, externals.first).covered_through
      assert_nil checkpoint(connection, externals.last)
      assert_equal 1, requests(client, :activities).size
    end
  end

  test "an unlinked successful balance still vetoes fallback for the linked profile balance" do
    with_sources(linked: 1) do |connection, externals, _accounts, client|
      client.statement = ->(id) { id == externals.last.external_id ? [] : deny! }

      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, connection.syncs.create!) }

      assert_equal 2, requests(client, :statement).size
      assert_empty requests(client, :transfers)
      unlinked = probe_batches(connection).find_by!(external_account: externals.last)
      assert_equal "retained", unlinked.source_binding["publication"]
      assert_nil unlinked.source_binding["account_id"]
      assert_empty SourceRecord.where(external_account: externals.last)
    end
  end

  test "transient failure resumes only the missing probe and preserves earlier empty-success veto" do
    with_sources do |connection, externals, _accounts, client|
      first, second = externals.sort_by(&:id)
      client.statement = ->(id) { id == first.external_id ? [] : raise(Provider::Wise::WiseError.new("private timeout", :request_failed)) }
      sync = connection.syncs.create!
      assert_raises(Provider::AccountData::Error) { run_sync(connection, sync) }
      original = probe_batches(connection).sole.attributes
      assert_empty requests(client, :transfers)
      assert_empty connection.provider_sync_checkpoints.where(stream: "transactions")

      client.statement = ->(id) { assert_equal second.external_id, id; deny! }
      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync.reload) }

      assert_equal original, IngestionBatch.find(original.fetch("id")).attributes
      assert_equal [ first.external_id, second.external_id, second.external_id ], requests(client, :statement).map(&:second)
      assert_equal 2, requests(client, :inventory).size
      assert_empty requests(client, :transfers)
      assert_equal sync.created_at, checkpoint(connection, first).covered_through
    end
  end

  test "the actual job defers a bounded probe set and replays the original Sync and windows" do
    with_sources do |connection, externals, _accounts, client|
      sync = connection.syncs.create!
      observed_at = sync.created_at
      with_limit(:REQUESTS_PER_RUN, 1) do
        assert_enqueued_with(job: SyncJob, args: [ sync ]) { SyncJob.perform_now(sync) }
        assert sync.reload.pending?, sync.error
        assert_equal 1, sync.provider_attempt
        assert_equal 1, probe_batches(connection).count
        assert_empty requests(client, :transfers)
        assert_empty connection.provider_sync_checkpoints.where(stream: "transactions")
        travel 16.seconds
        SyncJob.perform_now(sync.reload)
      end

      assert sync.reload.completed?, sync.error
      assert_equal observed_at, sync.created_at
      assert_equal 2, requests(client, :statement).size
      assert_equal 2, requests(client, :inventory).size
      assert requests(client, :statement).all? { |request| request.last == observed_at }
      assert externals.all? { |external| checkpoint(connection, external).covered_through.nil? }
    end
  end

  test "same-Sync inventory window profile and link drift deny before another provider read" do
    %i[inventory window profile link].each do |drift|
      with_sources do |connection, externals, _accounts, client|
        sync = connection.syncs.create!
        with_limit(:REQUESTS_PER_RUN, 1) do
          assert_raises(Provider::AccountData::DeferredPage) { run_sync(connection, sync) }
        end
        case drift
        when :inventory then create_external_account(connection, external_id: "extra", currency: "EUR")
        when :window then externals.first.update!(sync_start_date: Date.new(2026, 9, 3))
        when :profile then connection.update!(settings: { "profile_id" => "different-profile" })
        when :link then externals.first.account_provider.touch
        end
        before = client.requests.dup

        assert_raises(Provider::AccountData::StaleWriter, drift.to_s) { run_sync(connection, sync.reload) }

        assert_equal before, client.requests
        assert_empty requests(client, :transfers)
      end
    end
  end

  test "statement posting is promoted normally and vetoes fallback in a later factory" do
    with_sources(count: 1) do |connection, externals, accounts, client|
      client.statement = ->(_id) { [ statement ] }
      first = connection.syncs.create!
      run_sync(connection, first)
      posted = accounts.sole.entries.sole
      history = connection.provider_sync_checkpoints.find_by!(stream: Provider::AccountData::Wise::StatementHistory::STREAM)
      assert_equal "account:#{externals.sole.id}", IngestionBatch.find(history.state.fetch("batch_id")).scope_key
      assert_provider_column_encrypted(probe_batches(connection).sole, :payload, "private-statement-reference")

      travel 1.minute
      client.statement = ->(_id) { deny! }
      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, connection.syncs.create!) }

      assert_empty requests(client, :transfers)
      assert_equal posted.id, accounts.sole.entries.sole.id
      assert_equal first.created_at, checkpoint(connection, externals.sole).covered_through
    end
  end

  test "same-Sync replay preserves a completed sibling and its newly promoted statement history" do
    with_sources do |connection, externals, accounts, client|
      client.statement = ->(id) { id == externals.first.external_id ? [ statement ] : deny! }
      sync = connection.syncs.create!
      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync) }
      posting = accounts.first.entries.sole.attributes
      receipt = connection.provider_sync_checkpoints.find_by!(stream: Provider::AccountData::Wise::StatementHistory::STREAM).attributes
      originals = probe_batches(connection).order(:id).map(&:attributes)
      reads = client.requests.dup

      travel 1.minute
      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync.reload) }

      assert_equal reads, client.requests
      assert_equal posting, accounts.first.entries.sole.attributes
      assert_equal receipt, ProviderSyncCheckpoint.find(receipt.fetch("id")).attributes
      assert_equal originals, probe_batches(connection).order(:id).map(&:attributes)
      assert_equal sync.created_at, checkpoint(connection, externals.first).covered_through
    end
  end

  test "a later Sync retains the unresolved fallback start rather than aging initial history out" do
    with_sources(count: 1) do |connection, externals, _accounts, client|
      connection.update!(sync_start_date: nil)
      first = connection.syncs.create!
      run_sync(connection, first)
      original_start = requests(client, :statement).sole[3]
      assert_equal first.created_at - 365.days, original_start
      assert_nil checkpoint(connection, externals.sole).covered_through

      travel 10.days
      run_sync(connection, connection.syncs.create!)

      assert_equal original_start, requests(client, :statement).last[3]
      assert_equal original_start, Time.iso8601(checkpoint(connection, externals.sole).state.dig("coverage", "start"))
      assert_nil checkpoint(connection, externals.sole).covered_through
    end
  end

  test "authentication and malformed statement failures never authorize transfer fallback" do
    %i[unauthorized invalid_response rate_limited].each do |type|
      with_sources(count: 1) do |connection, _externals, _accounts, client|
        client.statement = ->(_id) { raise Provider::Wise::WiseError.new("private error", type) }
        assert_raises(Provider::AccountData::Error) { run_sync(connection, connection.syncs.create!) }
        assert_empty probe_batches(connection)
        assert_empty requests(client, :transfers)
      end
    end
  end

  test "incomplete discovery cannot authorize statement probes or fallback" do
    with_sources do |connection, _externals, _accounts, client|
      Provider::AccountData::Wise.any_instance.expects(:list_accounts).raises(Provider::AccountData::IncompletePage, "partial inventory")
      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, connection.syncs.create!) }
      assert_empty client.requests
      assert_empty connection.ingestion_batches
    end
  end

  test "missing routed manifest and oversized stored captures refuse before more HTTP" do
    %i[missing oversized].each do |corruption|
      with_sources do |connection, _externals, _accounts, client|
        sync = connection.syncs.create!
        with_limit(:REQUESTS_PER_RUN, 1) do
          assert_raises(Provider::AccountData::DeferredPage) { run_sync(connection, sync) }
        end
        if corruption == :missing
          connection.ingestion_batches.where("scope_key LIKE 'wise_statement_manifest:%'").order(:id).first.delete
        else
          header = connection.ingestion_batches.find_by!(stream: Barrier::STREAM)
          header.update_columns(payload: { "invalid" => SecureRandom.base64(8192) })
        end
        before = client.requests.dup
        with_limit(:MAX_PAGE_BYTES, corruption == :oversized ? 1 : Barrier::MAX_PAGE_BYTES) do
          assert_raises(Provider::AccountData::Error) { run_sync(connection, sync.reload) }
        end
        assert_equal before, client.requests
      end
    end
  end

  private
    def with_limit(name, value)
      previous = Barrier.const_get(name)
      Barrier.send(:remove_const, name)
      Barrier.const_set(name, value)
      yield
    ensure
      Barrier.send(:remove_const, name)
      Barrier.const_set(name, previous)
    end

    def deny!
      raise Provider::Wise::WiseError.new("private denied body", :access_forbidden)
    end

    def requests(client, kind)
      client.requests.select { |request| request.first == kind }
    end

    def run_sync(connection, sync)
      Provider::AccountData::Syncer.new(connection).perform_sync(sync)
    end

    def probe_batches(connection)
      connection.ingestion_batches.where("scope_key LIKE 'wise_statement_probe:%'")
    end

    def checkpoint(connection, external)
      connection.provider_sync_checkpoints.find_by(stream: "transactions", scope_key: "account:#{external.id}")
    end

    def statement
      { "referenceNumber" => "private-statement-reference", "date" => "2026-09-12T00:00:00Z",
        "amount" => { "value" => "20", "currency" => "EUR" } }
    end

    def with_sources(count: 2, linked: count)
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "wise", credentials: { "token" => "private-token" },
          settings: { "profile_id" => "profile" }, sync_start_date: Date.new(2026, 9, 1))
        accounts = []
        externals = count.times.map do |index|
          external = create_external_account(connection, external_id: "balance-#{index}", currency: "EUR", account_type: "STANDARD")
          if index < linked
            account = connection.family.accounts.create!(name: "Wise barrier #{index}", currency: "EUR", balance: 100, accountable: Depository.new)
            accounts << account
            link = AccountProvider.create!(account: account, external_account: external)
            Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[transactions balances])
          end
          external
        end
        client = Client.new(externals.map(&:external_id))
        client.before_read = -> { assert_equal 0, ProviderConnection.connection.open_transactions, "provider I/O must follow admission commit" }
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
