require "test_helper"

# Separate connections need committed records so the writer and reassignment
# can observe each other without changing fixtures shared by other tests.
class Transaction::ReassignCategoryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Category reassignment race", currency: "USD")
    @categories = []
    %w[Source Concurrent Replacement].each do |name|
      @categories << Category.create!(
        family: @family, name: name, color: "#0d9488", lucide_icon: "tag"
      )
    end
    @source, @concurrent, @replacement = @categories
    @account = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 0, accountable: Depository.new
    )
    @entry = Entry.create!(
      account: @account, name: "Concurrent category edit", date: Date.current,
      amount: 10, currency: "USD", entryable: Transaction.new(category: @source)
    )
    @record = @entry.entryable
    Entry.where(id: @entry.id).update_all(updated_at: 1.hour.ago)
    @original_entry_timestamp = @entry.reload.updated_at
  end

  teardown do
    Entry.where(id: @entry.id).delete_all if @entry
    Transaction.where(id: @entry.entryable_id).delete_all if @entry
    Category.where(family_id: @family.id).delete_all if @family
    Account.where(id: @account.id).delete_all if @account
    Depository.where(id: @account.accountable_id).delete_all if @account
    Family.where(id: @family.id).delete_all if @family
  end

  %i[category family].each do |scope_type|
    test "#{scope_type} reassignment preserves a category edit committed while waiting for its row lock" do
      scope = if scope_type == :category
        @source.transactions
      else
        @family.transactions.where(category_id: @source.id)
      end

      count = reassign_after_concurrent_edit(scope)

      assert_equal 0, count
      assert_equal @concurrent.id, @record.reload.category_id
      assert_equal @original_entry_timestamp, @entry.reload.updated_at
    end
  end

  private
    def reassign_after_concurrent_edit(scope)
      pool = ActiveRecord::Base.connection_pool
      assert_operator pool.size, :>=, 3, "race regression needs writer, worker, and observer connections"
      observer = Transaction.connection
      writer = pool.checkout
      worker = nil
      worker_pid = nil

      writer.transaction do
        writer.execute("SET LOCAL statement_timeout = '30s'")
        writer.execute("SET LOCAL lock_timeout = '30s'")
        writer_pid = writer.select_value("SELECT pg_backend_pid()")
        # Bypass Entryable's touch callback so only the reassignment can change
        # the entry timestamp being checked below.
        writer.execute(<<~SQL)
          UPDATE transactions
          SET category_id = #{writer.quote(@concurrent.id)}
          WHERE id = #{writer.quote(@record.id)}
        SQL

        backend_pids = Queue.new
        worker = Thread.new do
          pool.with_connection do |connection|
            connection.transaction do
              connection.execute("SET LOCAL statement_timeout = '30s'")
              connection.execute("SET LOCAL lock_timeout = '30s'")
              backend_pids << connection.select_value("SELECT pg_backend_pid()")
              Transaction.reassign_category!(scope, @replacement.id)
            end
          end
        end
        worker.report_on_exception = false
        worker_pid = wait_for_worker_pid(worker, backend_pids)
        wait_for_writer_lock(observer, worker, worker_pid, writer_pid)
      end

      assert worker.join(10), "reassignment worker did not finish after the writer committed"
      worker.value
    ensure
      begin
        # The transaction block has committed or rolled back the writer before
        # waiting for the worker, including assertion and synchronization failures.
        finish_worker(worker, observer, worker_pid)
      ensure
        pool.checkin(writer) if writer
      end
    end

    def wait_for_worker_pid(worker, backend_pids)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        return backend_pids.pop unless backend_pids.empty?
        unless worker.alive?
          worker.value # Propagate worker failures instead of reporting a timeout.
          flunk "reassignment worker finished before reporting its backend PID"
        end
        flunk "reassignment worker did not report its backend PID" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def wait_for_writer_lock(observer, worker, worker_pid, writer_pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        blocked = observer.uncached do
          observer.select_value("SELECT #{Integer(writer_pid)} = ANY(pg_blocking_pids(#{Integer(worker_pid)}))")
        end
        return if blocked
        unless worker.alive?
          worker.value
          flunk "reassignment finished before waiting on the concurrent writer"
        end
        flunk "reassignment did not wait on the concurrent writer" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def finish_worker(worker, observer, worker_pid)
      return unless worker&.alive?
      return if worker.join(5)

      observer.uncached { observer.select_value("SELECT pg_cancel_backend(#{Integer(worker_pid)})") } if worker_pid
      return if worker.join(5)

      worker.kill
      raise "reassignment worker could not be stopped" unless worker.join(5)
    rescue ActiveRecord::QueryCanceled
      # Cancellation above deliberately interrupts an unfinished SQL statement.
    end
end
