require "test_helper"

# A committed isolated family lets a normal assignment race with category
# deletion on a second connection without changing shared fixtures.
class Category::CacheInvalidationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Late category assignment", currency: "USD")
    @source = @family.categories.create!(
      name: "Empty source", color: "#0d9488", lucide_icon: "tag", updated_at: 2.hours.ago
    )
    @other = @family.categories.create!(
      name: "Initial category", color: "#0d9488", lucide_icon: "tag", updated_at: 1.hour.ago
    )
    @account = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 0, accountable: Depository.new
    )
    @entry = Entry.create!(
      account: @account, name: "Late source assignment", date: Date.current,
      amount: 10, currency: "USD", entryable: Transaction.new(category: @other)
    )
    @record = @entry.entryable
    Entry.where(id: @entry.id).update_all(updated_at: 1.day.ago)
  end

  teardown do
    Entry.where(id: @entry.id).delete_all if @entry
    Transaction.where(id: @entry.entryable_id).delete_all if @entry
    Category.where(family_id: @family.id).delete_all if @family
    Account.where(id: @account.id).delete_all if @account
    Depository.where(id: @account.accountable_id).delete_all if @account
    Family.where(id: @family.id).delete_all if @family
  end

  test "totals refresh when deletion nullifies an assignment committed after the reassignment callback" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ready = Queue.new
    resume = Queue.new
    pool = ActiveRecord::Base.connection_pool
    assert_operator pool.size, :>=, 2
    observer = Transaction.connection
    worker = nil
    worker_pid = nil
    original_reassignment = @source.method(:reassign_transactions_to_nothing)

    # Pause this category instance at the boundary between the actual callback
    # and dependent nullification; the original callback still runs unchanged.
    @source.define_singleton_method(:reassign_transactions_to_nothing) do
      count = original_reassignment.call
      ready << count
      resume.pop
      count
    end

    worker = Thread.new do
      pool.with_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL statement_timeout = '30s'")
          connection.execute("SET LOCAL lock_timeout = '30s'")
          worker_pid = connection.select_value("SELECT pg_backend_pid()")
          @source.destroy!
        end
      end
    end
    worker.report_on_exception = false
    assert_equal 0, wait_for_callback(worker, ready)

    @record.update!(category: @source)
    timestamp_before_delete = @entry.reload.updated_at
    category_timestamp = @family.categories.maximum(:updated_at)
    filters = { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ], active_accounts_only: false }
    before_version = observer.uncached { @family.entries_cache_version }
    assert_equal 0, observer.uncached { Transaction::Search.new(@family, filters: filters).totals.count }

    resume << true
    assert worker.join(10), "deletion worker did not finish"
    worker.value

    observer.uncached do
      assert_not Category.exists?(@source.id)
      assert_nil @record.reload.category_id
      assert_equal timestamp_before_delete, @entry.reload.updated_at
      assert_equal category_timestamp, @family.categories.maximum(:updated_at)
      search = Transaction::Search.new(@family, filters: filters)
      assert_equal 1, search.transactions_scope.count
      assert_equal 1, search.totals.count
      assert_not_equal before_version, @family.entries_cache_version
    end
  ensure
    begin
      finish_worker(worker, observer, worker_pid, resume)
    ensure
      Rails.cache = previous_cache
    end
  end

  private
    def wait_for_callback(worker, ready)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        return ready.pop unless ready.empty?
        unless worker.alive?
          worker.value
          flunk "deletion worker finished before its reassignment callback"
        end
        flunk "deletion worker did not reach its reassignment callback" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def finish_worker(worker, observer, worker_pid, resume)
      return unless worker&.alive?
      resume << true
      return if worker.join(10)

      observer.uncached { observer.select_value("SELECT pg_cancel_backend(#{Integer(worker_pid)})") } if worker_pid
      return if worker.join(5)

      worker.kill
      raise "deletion worker could not be stopped" unless worker.join(5)
    rescue ActiveRecord::QueryCanceled
      # Cancellation deliberately interrupts an unfinished SQL statement.
    end
end
