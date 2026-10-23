require "test_helper"
require "timeout"

class Transaction::MergeLockOrderTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Merge concurrency", currency: "USD")
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 1000, accountable: Depository.new)
    @posted = @account.entries.create!(name: "Posted", amount: 100, currency: "USD", date: Date.current, entryable: Transaction.new)
    @pending = @account.entries.create!(
      name: "Pending", amount: 100, currency: "USD", date: Date.current - 1.day,
      external_id: "pending-merge-lock-test", source: "enable_banking",
      entryable: Transaction.new(extra: {
        "enable_banking" => { "pending" => true },
        "potential_posted_match" => { "entry_id" => @posted.id }
      })
    )
  end

  teardown do
    begin
      @worker&.join(5)
    ensure
      if @worker&.alive?
        @worker.kill
        @worker.join
      end
      @account.entries.each(&:destroy!)
      @account.destroy!
      @family.destroy!
    end
  end

  %w[pending posted].each do |side|
    test "merge waits for the #{side} transaction before locking either entry" do
      target = side == "pending" ? @pending : @posted
      target.transaction.with_lock do
        ready = Queue.new
        pending_id = @pending.entryable_id
        @worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            pending = Transaction.find(pending_id)
            ready << connection.select_value("SELECT pg_backend_pid()")
            pending.merge_with_duplicate!
          end
        end
        worker_pid = Timeout.timeout(5) { ready.pop }
        Timeout.timeout(5) do
          loop do
            blocked = ActiveRecord::Base.uncached do
              ActiveRecord::Base.connection.select_value(
                "SELECT cardinality(pg_blocking_pids(#{Integer(worker_pid)})) > 0")
            end
            break if blocked
            assert @worker.alive?, "merge completed without waiting for the transaction lock"
            sleep 0.01
          end
        end

        # A converter or amount editor already holding the transaction lock
        # must be able to acquire its entry without forming a lock cycle.
        assert_nothing_raised do
          Entry.where(id: [ @pending.id, @posted.id ]).order(:id).lock("FOR UPDATE NOWAIT").load
        end
      end

      assert Timeout.timeout(5) { @worker.value }
      assert_not Entry.exists?(@pending.id)
      assert_equal "pending-merge-lock-test", @posted.transaction.reload.extra.dig("manual_merge", 0, "merged_from_external_id")
    end
  end
end
