require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinItem::PendingCleanupIntegrationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  # A public importer run reads discovery and then the dated account response.
  # The hook observes committed state between those two physical request slots.
  class AccountResponses
    attr_reader :requests

    def initialize(responses, &before_read)
      @responses = responses
      @before_read = before_read
      @requests = []
    end

    def get_accounts(_access_url, **options)
      requests << options
      @before_read&.call(requests.size)
      @responses.fetch(requests.size - 1).deep_dup
    end
  end

  setup do
    DebugLogEntry.stubs(:capture)
    ApplicationController.stubs(:render).returns("card")
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "public discovery and regular responses persist each pending cleanup change and count it once" do
    with_source do |item, source, sync, account|
      exact = add_entry(source, account, amount: 100, name: "Exact purchase pending")
      exact_posted = add_entry(source, account, pending: false, amount: 100, name: "Exact purchase settled")
      fuzzy = add_entry(source, account, amount: 300, name: "Cafe Morning Coffee pending")
      fuzzy_posted = add_entry(source, account, pending: false, amount: 330, name: "CAFE Morning Coffee booked")
      stale = add_entry(source, account, amount: 700, date: 9.days.ago.to_date, name: "Old authorization")
      untouched = add_unrelated_account(account.family)
      before_account = account.reload.attributes
      before_untouched = untouched.reload.attributes
      writes = []
      entry_callback = lambda do |entry|
        writes << [ :entry, entry.id ] if [ exact.id, stale.id ].include?(entry.id)
      end
      transaction_callback = lambda do |transaction|
        writes << [ :transaction, transaction.id ] if transaction.id == fuzzy.entryable_id
      end
      provider = two_responses(source) do |request|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        next unless request == 2
        assert exact.reload.excluded?
        assert stale.reload.excluded?
        assert_equal fuzzy_posted.id, fuzzy.transaction.reload.extra.fetch("potential_posted_match").fetch("entry_id")
      end

      Entry.set_callback(:update, :after, entry_callback)
      Transaction.set_callback(:update, :after, transaction_callback)
      begin
        import(item, sync, provider)
      ensure
        Entry.skip_callback(:update, :after, entry_callback)
        Transaction.skip_callback(:update, :after, transaction_callback)
      end

      assert_equal [ [ :entry, exact.id ], [ :entry, stale.id ], [ :transaction, fuzzy.entryable_id ] ].sort,
        writes.sort
      assert exact.reload.excluded?
      assert stale.reload.excluded?
      refute fuzzy.reload.excluded?
      refute exact_posted.reload.excluded?
      refute fuzzy_posted.reload.excluded?
      assert_equal before_account, account.reload.attributes
      assert_equal before_untouched, untouched.reload.attributes
      stats = sync.reload.sync_stats
      assert_equal 2, stats.fetch("api_requests")
      assert_equal 1, stats.fetch("pending_reconciled")
      assert_equal 1, stats.fetch("duplicate_suggestions_created")
      assert_equal 1, stats.fetch("stale_pending_excluded")
      assert_equal 0, stats.fetch("stale_unmatched_pending")
      assert_equal [ { "account_id" => account.id, "account_name" => account.name,
        "pending_name" => exact.name, "posted_name" => exact_posted.name } ], stats.fetch("pending_reconciled_details")
      assert_equal [ { "account_id" => account.id, "account_name" => account.name,
        "pending_name" => fuzzy.name, "posted_name" => fuzzy_posted.name } ], stats.fetch("duplicate_suggestions_details")
      assert_equal [ { "account_id" => account.id, "account_name" => account.name, "count" => 1 } ],
        stats.fetch("stale_pending_details")
      refute stats.key?("reconciliation_errors")
      assert_nil provider.requests.first.fetch(:start_date)
      assert provider.requests.last.fetch(:start_date).present?
    end
  end

  test "a cleanup SQL callback rollback retries on the regular response without false debounce or duplicate counters" do
    %i[exact fuzzy_suggestion stale].each do |kind|
      with_source do |item, source, sync, account|
        date = kind == :stale ? 10.days.ago.to_date : 2.days.ago.to_date
        pending = add_entry(source, account, amount: 100, date: date, name: "Cafe Morning Coffee pending")
        unless kind == :stale
          add_entry(source, account, pending: false, amount: kind == :exact ? 100 : 120,
            date: date, name: "Cafe Morning Coffee booked")
        end
        completed = add_entry(source, account, amount: 900, date: 10.days.ago.to_date, name: "Separate authorization")
        untouched = add_unrelated_account(account.family)
        before_account = account.reload.attributes
        before_untouched = untouched.reload.attributes
        model = kind == :fuzzy_suggestion ? Transaction : Entry
        record_id = kind == :fuzzy_suggestion ? pending.entryable_id : pending.id
        issued_writes = []
        callback = lambda do |record|
          next unless record.id == record_id
          issued_writes << if kind == :fuzzy_suggestion
            Transaction.find(record_id).extra.key?("potential_posted_match")
          else
            Entry.find(record_id).excluded?
          end
          raise IOError, "Private callback details" if issued_writes.size == 1
        end
        provider = two_responses(source) do |request|
          assert_equal 0, ApplicationRecord.connection.open_transactions
          next unless request == 2
          assert_equal [ true ], issued_writes, kind
          refute pending.reload.excluded?, kind
          assert_nil pending.transaction.reload.extra["potential_posted_match"], kind
          assert completed.reload.excluded?, kind
          discovery_stats = sync.reload.sync_stats
          assert_equal 0, discovery_stats.fetch("pending_reconciled", 0), kind
          assert_equal 0, discovery_stats.fetch("duplicate_suggestions_created", 0), kind
          assert_equal 1, discovery_stats.fetch("stale_pending_excluded"), kind
          assert_equal 1, discovery_stats.fetch("reconciliation_errors").size, kind
        end

        model.set_callback(:update, :after, callback)
        begin
          import(item, sync, provider)
        ensure
          model.skip_callback(:update, :after, callback)
        end

        assert_equal [ true, true ], issued_writes, kind
        assert_equal 2, provider.requests.size, kind
        if kind == :fuzzy_suggestion
          refute pending.reload.excluded?
          assert pending.transaction.reload.extra["potential_posted_match"].present?
        else
          assert pending.reload.excluded?
        end
        assert completed.reload.excluded?
        assert_equal before_account, account.reload.attributes, kind
        assert_equal before_untouched, untouched.reload.attributes, kind
        stats = sync.reload.sync_stats
        assert_equal 2, stats.fetch("api_requests"), kind
        assert_equal (kind == :exact ? 1 : 0), stats.fetch("pending_reconciled", 0), kind
        assert_equal (kind == :fuzzy_suggestion ? 1 : 0), stats.fetch("duplicate_suggestions_created", 0), kind
        assert_equal (kind == :stale ? 2 : 1), stats.fetch("stale_pending_excluded"), kind
        assert_equal stats.fetch("stale_pending_excluded"), stats.fetch("stale_pending_details").sole.fetch("count"), kind
        assert_equal 0, stats.fetch("stale_unmatched_pending"), kind
        error = stats.fetch("reconciliation_errors").sole
        assert_equal "pending_cleanup", error.fetch("context")
        assert_equal account.id, error.fetch("account_id")
        assert_equal "IOError: pending cleanup failed", error.fetch("error")
        refute_includes stats.inspect, "Private callback details"
        refute stats.key?("accounts_skipped")
        refute stats.key?("errors")
      end
    end
  end

  test "an actual cleanup row lock denial escapes the public importer without recovery stats or a holdings job" do
    with_source(investment: true) do |item, source, sync, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      before_account = account.reload.attributes
      before_entry = pending.reload.attributes
      before_denial = nil
      callback = lambda do |saved|
        before_denial = Sync.find(sync.id).sync_stats.deep_dup if saved.id == source.id
      end
      provider = AccountResponses.new([ response(source, holdings: true) ]) do
        assert_equal 0, ApplicationRecord.connection.open_transactions
      end
      SimplefinHoldingsApplyJob.expects(:enqueue_for).never
      DebugLogEntry.expects(:capture).never

      SimplefinAccount.set_callback(:update, :after, callback)
      begin
        with_locked_entry(pending) do
          assert_raises(Fence::Busy) { import(item, sync, provider) }
        end
      ensure
        SimplefinAccount.skip_callback(:update, :after, callback)
      end

      assert before_denial
      assert_equal before_denial, sync.reload.sync_stats
      assert_equal before_account, account.reload.attributes
      assert_equal before_entry, pending.reload.attributes
      assert_equal 1, provider.requests.size
      assert_empty account.holdings
      %w[accounts_skipped errors reconciliation_errors pending_reconciled stale_pending_excluded].each do |key|
        refute sync.sync_stats.key?(key), key
      end
    end
  end

  test "native ownership refuses public import before resetting stats or reading the provider" do
    with_source(investment: true) do |item, source, sync, account|
      pending = add_entry(source, account, date: 10.days.ago.to_date)
      ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "active")
      sync.update_columns(sync_stats: { "retained" => "original run" })
      before_stats = sync.reload.sync_stats
      before_account = account.reload.attributes
      provider = mock("denied SimpleFIN provider")
      provider.expects(:get_accounts).never
      SimplefinHoldingsApplyJob.expects(:enqueue_for).never

      assert_raises(Fence::OwnershipChanged) { import(item, sync, provider) }

      assert_equal before_stats, sync.reload.sync_stats
      assert_equal before_account, account.reload.attributes
      refute pending.reload.excluded?
    end
  end

  private

    def import(item, sync, provider)
      SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).import
    end

    def two_responses(source, &before_read)
      payload = response(source)
      AccountResponses.new([ payload, payload ], &before_read)
    end

    def response(source, holdings: false)
      account = { id: source.account_id, name: source.name, type: source.account_type,
        currency: "USD", balance: "300", transactions: source.reload.raw_transactions_payload.deep_dup }
      if holdings
        account[:holdings] = [ { id: "holding", symbol: "AAPL", quantity: 1, market_value: 50, currency: "USD" } ]
      end
      { accounts: [ account ], errors: [] }.with_indifferent_access
    end

    def add_entry(source, account, pending: true, amount: 100, date: 2.days.ago.to_date, name: "Purchase")
      amount = BigDecimal(amount.to_s)
      raw_id = SecureRandom.uuid
      entry = account.entries.create!(source: "simplefin", external_id: "simplefin_#{raw_id}", name: name,
        amount: amount, currency: "USD", date: date,
        entryable: Transaction.new(extra: { "simplefin" => { "pending" => pending } }))
      raw = { "id" => raw_id, "amount" => (-amount).to_s("F"), "currency" => "USD",
        "posted" => date.iso8601, "transacted_at" => date.iso8601, "pending" => pending, "description" => name }
      source.update!(raw_transactions_payload: source.reload.raw_transactions_payload + [ raw ])
      entry
    end

    def add_unrelated_account(family)
      Account.create!(family: family, name: "Unrelated financial balance", currency: "USD",
        balance: 987, cash_balance: 321, accountable: Depository.new)
    end

    def with_locked_entry(entry)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Entry.transaction do
            Entry.lock.find(entry.id)
            entered << true
            release.pop
          end
        end
      rescue => error
        entered << error
      end
      admission = Timeout.timeout(5) { entered.pop }
      raise admission if admission.is_a?(Exception)
      yield
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end

    def with_source(investment: false)
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN pending importer integration")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access",
          last_synced_at: 1.day.ago)
        source = item.simplefin_accounts.create!(name: investment ? "Brokerage" : "Checking source",
          account_id: SecureRandom.uuid, account_type: investment ? "investment" : "checking",
          currency: "USD", current_balance: 100, raw_transactions_payload: [])
        sync = item.syncs.create!
        account = Account.create!(family: family, name: "Selected financial account", currency: "USD",
          balance: 100, cash_balance: 80, accountable: investment ? Investment.new : Depository.new)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, sync, account
      ensure
        if family&.persisted?
          ProviderMigrationControl.where(family: family).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.reload.each(&:destroy!)
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end
end
