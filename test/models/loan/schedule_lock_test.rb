require "test_helper"
require "timeout"
require "ostruct"

class Loan::ScheduleLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @loan = Loan.create!(rate_type: "variable", interest_rate: 5, start_date: Date.new(2024, 1, 1))
  end

  teardown do
    @loan.destroy!
  end

  test "provider schedules assembled from stale instances retain both dates" do
    stale = Loan.find(@loan.id)
    @loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6" } }, source: "redbark")
    stale.enrich_attributes({ variable_rate_schedule: { "2026-02-01" => "7" } }, source: "plaid")

    assert_equal({ "2026-01-01" => "6", "2026-02-01" => "7" }, @loan.reload.variable_rate_schedule)
  end

  test "the last provider update for the same date wins" do
    stale = Loan.find(@loan.id)
    @loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6" } }, source: "redbark")
    stale.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "7" } }, source: "plaid")

    assert_equal({ "2026-01-01" => "7" }, @loan.reload.variable_rate_schedule)
  end

  test "the outer lock refreshes the rate before deciding that a provider reading is unchanged" do
    @loan.update!(interest_rate: 6)
    stale = Loan.find(@loan.id)
    as_of = Date.new(2026, 2, 1)
    assert_equal BigDecimal("6"), stale.current_variable_rate(as_of)
    @loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "7" } }, source: "redbark")

    stale.with_schedule_lock do
      unless stale.current_variable_rate(as_of) == BigDecimal("6")
        stale.enrich_attributes(
          { variable_rate_schedule: stale.variable_rate_schedule.merge(as_of.iso8601 => "6") }, source: "plaid"
        )
      end
    end

    assert_equal({ "2026-01-01" => "7", "2026-02-01" => "6" }, @loan.reload.variable_rate_schedule)
  end

  test "provider schedule updates respect user attribute locks" do
    stale = Loan.find(@loan.id)
    @loan.lock_attr!(:variable_rate_schedule)
    stale.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6" } }, source: "redbark")

    assert_empty @loan.reload.variable_rate_schedule
    assert_empty @loan.data_enrichments
  end

  test "a form snapshot preserves new provider dates and allows deleting rendered dates" do
    @loan.update!(variable_rate_schedule: { "2026-01-01" => "6" })
    snapshot = @loan.rate_schedule_snapshot
    @loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6", "2026-02-01" => "7" } }, source: "redbark")

    @loan.with_schedule_lock do
      @loan.update!(rate_schedule_snapshot: snapshot, rate_changes: [ { effective_date: "2026-03-01", rate: "8" } ])
    end

    assert_equal({ "2026-02-01" => "7", "2026-03-01" => "8.0" }, @loan.reload.variable_rate_schedule)
  end

  test "an invalid form snapshot refuses the save" do
    assert_not @loan.update(rate_schedule_snapshot: "[]", rate_changes: [])
    assert @loan.errors.any?
  end

  test "a committed loan retries after a real rollback by explicitly reloading the same instance" do
    assert_equal 0, Loan.connection.open_transactions
    loan = @loan
    loan.update!(variable_rate_schedule: { "2026-01-01" => "7" })
    snapshot = loan.rate_schedule_snapshot
    rows = [ { effective_date: "2026-03-01", rate: "9" } ]

    Loan.transaction do
      loan.update!(rate_schedule_snapshot: snapshot, rate_changes: rows)
      assert_not loan.changed_for_autosave?
      assert_equal({ "2026-03-01" => "9.0" }, Loan.find(loan.id).variable_rate_schedule)
      raise ActiveRecord::Rollback
    end

    assert_equal 0, Loan.connection.open_transactions
    assert_equal({ "2026-01-01" => "7" }, Loan.find(loan.id).variable_rate_schedule)
    assert loan.has_changes_to_save?
    error = assert_raises(RuntimeError) { loan.with_schedule_lock { flunk "Dirty retries must not acquire the lock" } }
    assert_includes error.message, "unpersisted changes"

    loan_id = loan.id
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Loan.find(loan_id).enrich_attributes(
          { variable_rate_schedule: { "2026-01-01" => "7", "2026-02-01" => "8" } }, source: "redbark"
        )
      end
    end.value

    assert_same loan, loan.reload
    assert_not loan.has_changes_to_save?
    loan.with_schedule_lock do
      loan.assign_attributes(rate_schedule_snapshot: snapshot, rate_changes: rows)
      2.times do
        assert loan.valid?
        assert_equal [ "2026-02-01", "2026-03-01" ], loan.rate_change_rows.pluck(:effective_date)
      end
      loan.save!
    end

    assert_equal({ "2026-02-01" => "8", "2026-03-01" => "9.0" }, Loan.find(loan.id).variable_rate_schedule)
    assert_not loan.changed_for_autosave?
  end

  test "concurrent connections serialize provider schedule writes" do
    held = Queue.new
    release = Queue.new
    second_pid = Queue.new
    id = @loan.id

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
        loan = Loan.find(id)
        loan.with_schedule_lock do
          loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6" } }, source: "redbark")
          held << true
          Timeout.timeout(10) { release.pop }
        end
      end
    end
    Timeout.timeout(10) { held.pop }

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
        stale = Loan.find(id)
        second_pid << connection.select_value("SELECT pg_backend_pid()").to_i
        stale.enrich_attributes({ variable_rate_schedule: { "2026-02-01" => "7" } }, source: "plaid")
      end
    end
    pid = Timeout.timeout(10) { second_pid.pop }
    wait_for_lock(pid)
    release << true
    [ first, second ].each(&:value)

    assert_equal({ "2026-01-01" => "6", "2026-02-01" => "7" }, @loan.reload.variable_rate_schedule)
  ensure
    release << true
    stop_workers(first, second)
  end

  test "account-first provider updates and schedule writes use the same lock order" do
    account = families(:empty).accounts.create!(name: "Loan", currency: "USD", balance: 0, accountable: @loan)
    held = Queue.new
    release = Queue.new
    second_pid = Queue.new
    id = @loan.id

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
        Account.transaction do
          provider_account = Account.find(account.id)
          provider_account.update!(name: "Provider name")
          held << true
          Timeout.timeout(10) { release.pop }
          provider_account.accountable.enrich_attributes({ subtype: "mortgage" }, source: "plaid")
        end
      end
    end
    Timeout.timeout(10) { held.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
        loan = Loan.find(id)
        second_pid << connection.select_value("SELECT pg_backend_pid()").to_i
        loan.with_schedule_lock do
          loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6" } }, source: "redbark")
        end
      end
    end
    pid = Timeout.timeout(10) { second_pid.pop }
    wait_for_lock(pid)
    release << true
    [ first, second ].each(&:value)

    assert_equal "mortgage", @loan.reload.subtype
    assert_equal({ "2026-01-01" => "6" }, @loan.variable_rate_schedule)
  ensure
    release << true
    stop_workers(first, second)
    account&.destroy!
  end

  [ PlaidAccount::Liabilities::MortgageProcessor, PlaidAccount::Liabilities::StudentLoanProcessor ].each do |processor_class|
    test "#{processor_class.name} shares the schedule writer lock order" do
      account = families(:empty).accounts.create!(name: "Loan", currency: "USD", balance: 0, accountable: @loan)
      held = Queue.new
      release = Queue.new
      second_pid = Queue.new

      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
          Account.transaction do
            writer_account = Account.find(account.id)
            writer_account.update!(name: "Updated")
            held << true
            Timeout.timeout(10) { release.pop }
            writer_account.loan.enrich_attributes({ variable_rate_schedule: { "2026-01-01" => "6" } }, source: "redbark")
          end
        end
      end
      Timeout.timeout(10) { held.pop }
      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
          provider = OpenStruct.new(current_account: Account.find(account.id), raw_liabilities_payload: {
            "mortgage" => { "interest_rate" => { "type" => "variable", "percentage" => 7 } },
            "student" => { "interest_rate_percentage" => 7 }
          })
          second_pid << connection.select_value("SELECT pg_backend_pid()").to_i
          processor_class.new(provider).process
        end
      end
      pid = Timeout.timeout(10) { second_pid.pop }
      wait_for_lock(pid)
      release << true
      [ first, second ].each(&:value)

      assert_equal BigDecimal("7"), @loan.reload.interest_rate
      assert_equal({ "2026-01-01" => "6" }, @loan.variable_rate_schedule)
    ensure
      release << true
      stop_workers(first, second)
      account&.destroy!
    end
  end

  test "worker cleanup cancels an active PostgreSQL query and releases its row lock" do
    held = Queue.new
    id = @loan.id
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
        connection.transaction do
          Loan.where(id: id).lock.pick(:id)
          held << connection.select_value("SELECT pg_backend_pid()").to_i
          connection.select_value("SELECT pg_sleep(30)")
        end
      end
    end
    worker.report_on_exception = false
    pid = Timeout.timeout(10) { held.pop }
    Timeout.timeout(10) do
      ActiveRecord::Base.uncached do
        sleep 0.01 until ActiveRecord::Base.connection.select_value("SELECT wait_event = 'PgSleep' FROM pg_stat_activity WHERE pid = #{pid}")
      end
    end

    stop_workers(worker, wait: 0)

    assert_not worker.alive?
    assert_equal id, Loan.where(id: id).lock("FOR UPDATE NOWAIT").pick(:id)
  ensure
    stop_workers(worker, wait: 0)
  end

  test "worker cleanup terminates a blocked Ruby worker and releases its transaction" do
    held = Queue.new
    id = @loan.id
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:schedule_lock_backend_pid] = connection.select_value("SELECT pg_backend_pid()").to_i
        Loan.find(id).with_lock do
          held << true
          Queue.new.pop
        end
      end
    end
    worker.report_on_exception = false
    Timeout.timeout(10) { held.pop }

    stop_workers(worker, wait: 0)

    assert_not worker.alive?
    assert_equal id, Loan.where(id: id).lock("FOR UPDATE NOWAIT").pick(:id)
  ensure
    stop_workers(worker, wait: 0)
  end

  test "worker cleanup continues after backend termination fails" do
    stuck_worker = mock("stuck worker")
    finished_worker = mock("finished worker")
    expects(:join_worker).with(stuck_worker, 1).times(4).returns(false)
    expects(:cancel_worker_query).with(stuck_worker).raises(ActiveRecord::StatementInvalid)
    stuck_worker.expects(:kill)
    expects(:cancel_worker_query).with(stuck_worker, terminate: true).raises(ActiveRecord::StatementInvalid)
    expects(:join_worker).with(finished_worker, 1).returns(true)

    error = assert_raises(RuntimeError) { stop_workers(stuck_worker, finished_worker) }
    assert_equal "Concurrent test worker did not stop", error.message
  end

  private
    def stop_workers(*workers, wait: 1)
      stuck = []
      workers.compact.each do |worker|
        next if join_worker(worker, wait)

        begin
          cancel_worker_query(worker)
        rescue ActiveRecord::StatementInvalid
          # Still terminate the Ruby worker if cancellation itself fails.
        end
        next if join_worker(worker, 1)

        worker.kill
        next if join_worker(worker, 1)

        begin
          cancel_worker_query(worker, terminate: true)
        rescue ActiveRecord::StatementInvalid
          # Finish checking every worker even if backend termination fails.
        end
        stuck << worker unless join_worker(worker, 1)
      end
      raise "Concurrent test worker did not stop" if stuck.any?
    end

    def cancel_worker_query(worker, terminate: false)
      pid = worker[:schedule_lock_backend_pid]
      return unless pid

      function = terminate ? "pg_terminate_backend" : "pg_cancel_backend"
      ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value("SELECT #{function}(#{pid.to_i})")
      end
    end

    def join_worker(worker, wait)
      worker.join(wait)
    rescue StandardError
      !worker.alive?
    end

    def wait_for_lock(pid)
      Timeout.timeout(10) do
        ActiveRecord::Base.uncached do
          sleep 0.01 until ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid}))").positive?
        end
      end
    end
end
