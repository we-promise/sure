require "test_helper"
require "concurrent"

# A fee saved on a pending transfer while another connection deletes it under
# its row lock. Real threads on real connections, so this needs real commits.
class TransfersControllerConcurrencyTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Transfer Fee Race", currency: "USD")
    @family.create_subscription!(status: "trialing", trial_ends_at: 1.week.from_now)
    @user = @family.users.create!(
      email: "fee-race-#{SecureRandom.hex(4)}@example.com", password: user_password_test,
      first_name: "Fee", last_name: "Race", role: :admin, onboarded_at: Time.current
    )
    @gbp = Account.create!(family: @family, owner: @user, name: "GBP current", currency: "GBP", balance: 0, accountable: Depository.new)
    @cad = Account.create!(family: @family, owner: @user, name: "CAD current", currency: "CAD", balance: 0, accountable: Depository.new)

    @outflow = create_transaction(date: 1.day.ago.to_date, account: @gbp, amount: 400, currency: "GBP")
    coincidental_inflow = create_transaction(date: 1.day.ago.to_date, account: @cad, amount: -680, currency: "CAD")
    @guess = Transfer.create!(inflow_transaction: coincidental_inflow.entryable, outflow_transaction: @outflow.entryable, status: "pending")

    sign_in @user
  end

  teardown do
    @holder&.kill&.join
    next unless @family&.persisted?

    account_ids = Account.where(family_id: @family.id).pluck(:id)
    transaction_ids = Transaction.joins(:entry).where(entries: { account_id: account_ids }).select(:id)
    Transaction.where(id: transaction_ids).update_all(transfer_id: nil)
    Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids)).delete_all
    Entry.where(account_id: account_ids).destroy_all
    @family.destroy
  end

  test "a fee saved while the transfer is deleted under its lock is refused cleanly" do
    holding = Concurrent::CountDownLatch.new(1)

    # Another connection deletes the transfer and holds its locks, uncommitted,
    # until the fee request waits on the transfer's row lock.
    @holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Transfer.transaction do
          Transfer.lock.find(@guess.id)
          @guess.destroy!
          holding.count_down
          wait_for_lock_waiter
        end
      end
    end

    assert holding.wait(10), "the holder never deleted the transfer"
    patch transfer_url(@guess), params: { transfer: { source_fee_amount: 5 } }

    assert @holder.value, "the fee request never waited on the transfer's row lock"
    assert_redirected_to transactions_url
    assert_equal I18n.t("transfers.update.removed"), flash[:alert]
    assert_not Transfer.exists?(@guess.id)
    assert_equal 0, Entry.where(account_id: @gbp.id, amount: 5).count, "no orphaned fee transaction"
  end

  test "a fee edit gives up when the transfer stays locked past the timeout" do
    Transfer.stubs(:edit_lock_timeout).returns("200ms")
    holding = Concurrent::CountDownLatch.new(1)
    released = Concurrent::CountDownLatch.new(1)

    # A long-running writer holds the transfer's row lock until the request
    # has answered, or for at most 10 seconds.
    @holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Transfer.transaction do
          Transfer.lock.find(@guess.id)
          holding.count_down
          released.wait(10)
        end
      end
    end

    assert holding.wait(10), "the holder never took the lock"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    patch transfer_url(@guess), params: { transfer: { source_fee_amount: 5 } }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    released.count_down
    @holder.join

    assert_redirected_to transactions_url
    assert_equal I18n.t("transfers.update.busy"), flash[:alert]
    assert_operator elapsed, :<, 5, "the request waited for the holder instead of timing out"
    assert_equal 0, Entry.where(account_id: @gbp.id, amount: 5).count, "no fee transaction"
    assert Transfer.exists?(@guess.id)
  end

  test "a saved edit leaves the connection's lock timeout as it was" do
    connection = ActiveRecord::Base.connection
    before = connection.select_value("SHOW lock_timeout")

    patch transfer_url(@guess), params: { transfer: { notes: "Bank fee" } }

    assert_redirected_to transactions_url
    assert_equal "Bank fee", @guess.reload.notes
    assert_equal before, connection.select_value("SHOW lock_timeout")
  end

  private
    # True once another backend on this database waits on a lock we hold.
    def wait_for_lock_waiter(timeout: 10)
      connection = ActiveRecord::Base.connection
      deadline = Time.current + timeout
      until Time.current > deadline
        # Backend status is otherwise read once per transaction.
        connection.execute("SELECT pg_stat_clear_snapshot()")
        waiting = connection.select_value(<<~SQL.squish)
          SELECT COUNT(*) FROM pg_stat_activity a
          WHERE a.datname = current_database()
            AND a.pid <> pg_backend_pid()
            AND pg_backend_pid() = ANY(pg_blocking_pids(a.pid))
        SQL
        return true if waiting.to_i.positive?

        sleep 0.05
      end
      false
    end
end
