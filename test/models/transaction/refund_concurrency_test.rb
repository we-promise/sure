require "test_helper"
require "timeout"

class Transaction::RefundConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Refund concurrency", currency: "USD")
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 1000, accountable: Depository.new)
    @purchase = @account.entries.create!(name: "Shirts", amount: 1000, currency: "USD", date: Date.current, entryable: Transaction.new)
    @refund = @account.entries.create!(name: "Return", amount: -800, currency: "USD", date: Date.current, entryable: Transaction.new)
    @splits = [ { name: "Keep", amount: 200 }, { name: "Return", amount: 800 } ]
  end

  teardown do
    @worker&.join(5) || @worker&.kill
    @account.entries.where(parent_entry_id: nil).each(&:destroy!)
    @account.destroy!
    @family.destroy!
  end

  test "linking waits for an in-flight split and rejects the split parent" do
    @purchase.transaction.with_lock do
      start_worker do
        purchase = Transaction.find(@purchase.entryable_id)
        purchase.entry # Simulate a previously loaded detail view.
        -> { Transaction.find(@refund.entryable_id).mark_as_refund!(purchase: purchase) }
      end
      assert_worker_waits_for_lock
      @purchase.split!(@splits)
    end

    assert_equal :rejected, worker_result
    assert_nil @refund.transaction.reload.refund_of_id
    assert_equal 2, @purchase.child_entries.count
  end

  test "splitting waits for an in-flight link and rejects the linked purchase" do
    @purchase.transaction.with_lock do
      start_worker do
        purchase = Entry.find(@purchase.id)
        purchase.transaction
        -> { purchase.split!(@splits) }
      end
      assert_worker_waits_for_lock
      @refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    end

    assert_equal :rejected, worker_result
    assert_equal @purchase.entryable_id, @refund.transaction.reload.refund_of_id
    assert_empty @purchase.child_entries
  end

  private
    def start_worker
      ready = Queue.new
      @worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          operation = yield
          ready << connection.select_value("SELECT pg_backend_pid()")
          operation.call
          :completed
        rescue ActiveRecord::RecordInvalid
          :rejected
        end
      end
      @worker_pid = Timeout.timeout(5) { ready.pop }
    end

    def assert_worker_waits_for_lock
      Timeout.timeout(5) do
        loop do
          blocked = ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value(
              "SELECT cardinality(pg_blocking_pids(#{Integer(@worker_pid)})) > 0")
          end
          break if blocked
          assert @worker.alive?, "operation committed without waiting for the purchase lock"
          sleep 0.01
        end
      end
    end

    def worker_result
      Timeout.timeout(5) { @worker.value }
    end
end
