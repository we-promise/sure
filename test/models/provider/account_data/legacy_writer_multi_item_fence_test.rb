require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::LegacyWriterMultiItemFenceTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "a lifecycle admits a sorted deduplicated set of fresh receivers on one session" do
    with_items do |up, simplefin|
      stale_up = UpItem.find(up.id)
      stale_up.name = "Unsaved stale name"
      simplefin.upstream_account_ids = [ "Untrusted previous discovery" ]
      keys = [ simplefin, up ].map { |item| Fence.new(item).lock_key }
      lock_queries = []

      result = capture_advisory_queries(lock_queries) do
        Fence.with_items([ stale_up, simplefin, up ]) do |current|
          assert current.frozen?
          assert_equal [ simplefin.id, up.id ], current.map(&:id)
          assert_equal 0, ApplicationRecord.connection.open_transactions
          assert_not_same simplefin, current.first
          assert_not_same stale_up, current.last
          assert_equal up.name, current.last.name
          assert_nil current.first.upstream_account_ids
          current.last.update!(name: "Admitted lifecycle")
          :finished
        end
      end

      assert_equal :finished, result
      assert_equal keys.map { |key| "SELECT pg_try_advisory_lock_shared(#{key})" } +
        keys.reverse.map { |key| "SELECT pg_advisory_unlock_shared(#{key})" }, lock_queries
      assert_equal "Admitted lifecycle", up.reload.name
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_empty ProviderMigrationControl.where(legacy_id: [ up.id, simplefin.id ])
    end
  end

  test "all identities and family claims are validated before any physical lock" do
    with_items do |up, simplefin|
      foreign_claim = UpItem.find(up.id)
      foreign_claim.family_id = families(:empty).id
      [ [ up, foreign_claim ], [ up, accounts(:depository) ], [ up, UpItem.new ], nil, UpItem.all ].each do |invalid|
        queries = []
        capture_advisory_queries(queries) do
          assert_raises(Fence::InvalidSource) { Fence.with_items(invalid) { flunk "Invalid set cannot enter" } }
        end
        assert_empty queries
      end
      assert_raises(ArgumentError) { Fence.with_items([ up, simplefin ], operation: :publish) { flunk } }
    end
  end

  test "all held members exclude a drain and release after an operation error" do
    with_items do |up, simplefin|
      failure = IOError.new("Lifecycle failed")
      caught = assert_raises(IOError) do
        Fence.with_items([ up, simplefin ]) do
          assert_equal [ :busy, :busy ], in_another_session { [ try_drain(up), try_drain(simplefin) ] }
          raise failure
        end
      end
      assert_same failure, caught
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_equal [ :drained, :drained ], in_another_session { [ try_drain(up), try_drain(simplefin) ] }
    end
  end

  test "contention on a later sorted member releases the already acquired prefix without entering" do
    with_items do |up, simplefin|
      queries = []
      while_drained_in_another_session(up) do
        capture_advisory_queries(queries) do
          assert_raises(Fence::Busy) { Fence.with_items([ up, simplefin ]) { flunk "Partial admission cannot enter" } }
        end
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      end
      first_key, second_key = [ simplefin, up ].map { |item| Fence.new(item).lock_key }
      assert_equal [ "SELECT pg_try_advisory_lock_shared(#{first_key})",
        "SELECT pg_try_advisory_lock_shared(#{second_key})", "SELECT pg_advisory_unlock_shared(#{first_key})" ], queries
      assert_equal [ :drained, :drained ], in_another_session { [ try_drain(simplefin), try_drain(up) ] }
    end
  end

  test "a rejected later ownership check releases the entire set before any lifecycle writes" do
    with_items do |up, simplefin|
      control_for(up, state: "quiescing")
      queries = capture_sql_queries do
        assert_raises(Fence::OwnershipChanged) do
          Fence.with_items([ up, simplefin ]) { flunk "Every source must be admitted before the block" }
        end
      end
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_equal [ :drained, :drained ], in_another_session { [ try_drain(simplefin), try_drain(up) ] }
    end
  end

  test "an acquisition with a lost response disconnects the session and releases every possible lock" do
    with_items do |up, simplefin|
      database = ApplicationRecord.connection
      original = database.method(:select_value)
      last_query = "SELECT pg_try_advisory_lock_shared(#{Fence.new(up).lock_key})"
      failure = IOError.new("Lock result was lost")
      interrupted = lambda do |sql, *arguments, **keywords|
        result = original.call(sql, *arguments, **keywords)
        raise failure if sql == last_query
        result
      end

      database.stub(:select_value, interrupted) do
        caught = assert_raises(IOError) { Fence.with_items([ up, simplefin ]) { flunk "Unknown acquisition cannot enter" } }
        assert_same failure, caught
      end
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      assert_equal [ :drained, :drained ], in_another_session { [ try_drain(simplefin), try_drain(up) ] }
    end
  end

  test "an uncertain release disconnects remaining locks and preserves the original operation error" do
    with_items do |up, simplefin|
      [ nil, IOError.new("Lifecycle operation failed") ].each do |operation_error|
        database = ApplicationRecord.connection
        original = database.method(:select_value)
        first_release = "SELECT pg_advisory_unlock_shared(#{Fence.new(up).lock_key})"
        lost_release = lambda do |sql, *arguments, **keywords|
          sql == first_release ? false : original.call(sql, *arguments, **keywords)
        end

        database.stub(:select_value, lost_release) do
          caught = assert_raises(operation_error ? IOError : Fence::OwnershipChanged) do
            Fence.with_items([ up, simplefin ]) { raise operation_error if operation_error }
          end
          assert_same operation_error, caught if operation_error
        end
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal [ :drained, :drained ], in_another_session { [ try_drain(simplefin), try_drain(up) ] }
      end
    end
  end

  test "nested item and subset calls reuse their own admitted receivers inside a write transaction" do
    with_items do |up, simplefin|
      admitted = nil
      Fence.with_items([ up, simplefin ]) do |current|
        admitted = current
        current.first.upstream_account_ids = [ "Observed inside this permit" ]
        current.last.name = "Current unsaved lifecycle name"
        ApplicationRecord.transaction do
          Fence.with_item(up) do |current_up|
            assert_same current.last, current_up
            Fence.with_item(simplefin) do |current_simplefin|
              assert_same current.first, current_simplefin
              assert_equal [ "Observed inside this permit" ], current_simplefin.upstream_account_ids
              Fence.with_items([ up, up ]) { |subset| assert_same current_up, subset.fetch(0) }
            end
            assert_equal "Current unsaved lifecycle name", current_up.name
          end
          Fence.with_items([]) { |subset| assert_empty subset }
        end
        assert_equal [ :busy, :busy ], in_another_session { [ try_drain(up), try_drain(simplefin) ] }
      end

      Fence.with_items(admitted) do |later|
        assert_not_same admitted.first, later.first
        assert_nil later.first.upstream_account_ids
        assert_equal up.name, later.last.name
      end
    end
  end

  test "nested requests recheck only requested sources including deletion of earlier members" do
    with_items do |up, simplefin|
      Fence.with_items([ up, simplefin ]) do |current|
        ApplicationRecord.transaction do
          current.first.destroy!
          Fence.with_items([ up ]) { |subset| assert_same current.last, subset.fetch(0) }
          Fence.with_item(up) { |item| assert_same current.last, item }
          assert_raises(Fence::OwnershipChanged) { Fence.with_item(simplefin) { flunk "Deleted source cannot reenter" } }
        end
      end
      assert_not SimplefinItem.exists?(simplefin.id)
    end
  end

  test "a nested member always rechecks its current ownership despite a cached source" do
    with_items do |up, simplefin|
      control = control_for(up)
      Fence.with_items([ up, simplefin ]) do |current|
        ApplicationRecord.cache do
          Fence.with_item(up) { |item| assert_same current.last, item }
          control.update!(state: "quiescing")
          assert_raises(Fence::OwnershipChanged) { Fence.with_items([ up ]) { flunk "Cached grant must not authorize" } }
          Fence.with_item(simplefin) { |item| assert_same current.first, item }
        end
      end
    end
  end

  test "a group cannot widen or change lock mode and initial nonempty entry rejects existing transactions" do
    with_items do |up, simplefin|
      Fence.with_item(up) do
        assert_raises(ArgumentError) { Fence.with_items([ up, simplefin ]) { flunk } }
      end
      Fence.with_items([ up, simplefin ]) do
        assert_raises(ArgumentError) { Fence.with_exclusive(up) { flunk } }
        assert_raises(Fence::InvalidSource) { Fence.assert_exclusive!(up) }
      end
      Fence.with_exclusive(up) do
        assert_equal up.id, Fence.assert_exclusive!(up).id
        assert_raises(ArgumentError) { Fence.with_items([ up ]) { flunk } }
        assert_raises(ArgumentError) { Fence.with_items([]) { flunk } }
      end
      ApplicationRecord.transaction do
        assert_raises(ArgumentError) { Fence.with_items([ up, simplefin ]) { flunk } }
      end
    end
  end

  test "an empty lifecycle set still prevents nested callbacks from adding an item" do
    with_items do |up, _simplefin|
      queries = []
      capture_advisory_queries(queries) do
        result = Fence.with_items([]) do |items|
          assert_empty items
          assert items.frozen?
          ApplicationRecord.transaction do
            assert_raises(ArgumentError) { Fence.with_item(up) { flunk } }
            assert_raises(ArgumentError) { Fence.with_items([ up ]) { flunk } }
          end
          :empty_lifecycle
        end
        assert_equal :empty_lifecycle, result
      end
      assert_empty queries
      assert_equal :drained, in_another_session { try_drain(up) }
    end
  end

  test "an initial empty set may enter an existing transaction without admitting later sources" do
    with_items do |up, _simplefin|
      queries = []
      capture_advisory_queries(queries) do
        ApplicationRecord.transaction do
          Fence.with_items([]) do |items|
            assert_empty items
            assert_operator ApplicationRecord.connection.open_transactions, :>, 0
            assert_raises(ArgumentError) { Fence.with_item(up) { flunk } }
            Fence.with_items([]) { |nested| assert_empty nested }
          end
        end
      end
      assert_empty queries
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
    end
  end

  test "account subsets and Sync contexts select the exact admitted member instead of a global receiver" do
    with_items do |up, simplefin|
      source = up.up_accounts.create!(account_id: "multi-scope", name: "Source", currency: "AUD", current_balance: 5)
      sync = up.syncs.create!
      stale = UpAccount.find(source.id)
      source.update!(current_balance: 12)

      Fence.with_items([ up, simplefin ]) do |current|
        admitted_up = current.last
        selected = Fence.scoped_accounts!(admitted_up, [ stale, stale ])
        assert_equal [ source.id, source.id ], selected.map(&:id)
        assert selected.all? { |account| account.current_balance == 12 }
        assert_equal sync.id, Fence.scoped_sync!(admitted_up, sync).id
        assert_raises(Fence::InvalidSource) { Fence.scoped_accounts!(up, [ source ]) }
        assert_raises(Fence::InvalidSource) { Fence.scoped_sync!(up, sync) }
        assert_raises(Fence::InvalidSource) { Fence.scoped_accounts!(current.first, [ source ]) }
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current.first, sync) }
        Fence.with_account(stale) { |account| assert_equal 12, account.current_balance }
      end
    end
  end

  private
    def with_items
      with_provider_encryption do
        up = UpItem.create!(family: families(:dylan_family), name: "Multi-item Up", access_token: "private-up-token")
        simplefin = SimplefinItem.create!(family: up.family, name: "Multi-item SimpleFIN", access_url: "https://example.com/fenced")
        begin
          yield up, simplefin
        ensure
          [ up, simplefin ].each do |item|
            ProviderMigrationControl.where(legacy_type: item.class.name, legacy_id: item.id).destroy_all
            item.class.find_by(id: item.id)&.destroy!
          end
        end
      end
    end

    def control_for(item, state: "legacy")
      manifest = Provider::AccountData::MigrationManifest.all.find { |entry| entry.item_type == item.class.name }
      ProviderMigrationControl.create!(family: item.family, provider_key: manifest.provider_key,
        legacy_type: item.class.name, legacy_id: item.id, state: state)
    end

    def capture_advisory_queries(queries)
      connection = ApplicationRecord.connection
      observer = lambda do |_name, _started, _finished, _unique_id, payload|
        next unless payload[:connection].equal?(connection) && payload[:sql].include?("pg_")
        queries << payload[:sql] if payload[:sql].match?(/pg_(?:try_advisory_lock|advisory_unlock)/)
      end
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { yield }
    end

    def try_drain(item)
      Fence.with_exclusive(item) { :drained }
    rescue Fence::Busy
      :busy
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new { ApplicationRecord.connection_pool.with_connection { block.call } }
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def while_drained_in_another_session(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready = Queue.new
      release = Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Fence.with_exclusive(item) do
            ready << true
            release.pop
          end
        end
      rescue StandardError => error
        ready << error
        raise
      end
      result = Timeout.timeout(5) { ready.pop }
      raise result if result.is_a?(Exception)
      yield
    ensure
      release << true if release
      if worker
        begin
          Timeout.timeout(5) { worker.value }
        ensure
          worker.kill if worker.alive?
          worker.join
        end
      end
    end
end
