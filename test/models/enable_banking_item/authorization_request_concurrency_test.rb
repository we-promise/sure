require "test_helper"
require "concurrent"

# The post-sync follow-up check treats a full-history request older than the
# latest sync as one that sync already saw. complete_authorization therefore
# takes a lock on the item row that conflicts with sync_later's before it
# reads the clock for the request: a sync created before that lock is older
# than the request, and one created after it waits for the request to commit,
# so its importer reads the request. The lock is FOR NO KEY UPDATE, taken
# after the session's accounts are imported, so neither another authorization
# nor a delete of the item deadlocks with it.
#
# Real threads on real connections, so this needs real commits.
class EnableBankingItem::AuthorizationRequestConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @item = EnableBankingItem.create!(
      family: families(:dylan_family),
      name: "Concurrency",
      country_code: "DE",
      application_id: "app",
      client_certificate: "cert",
      session_id: "sess",
      session_expires_at: 1.day.from_now,
      status: :good
    )
  end

  teardown do
    Sync.where(syncable: @item).delete_all
    EnableBankingAccount.where(enable_banking_item_id: @item.id).delete_all
    EnableBankingItem.where(id: @item.id).delete_all
  end

  test "a sync created while the authorization waits for the item lock is older than its request" do
    authorizing = EnableBankingItem.find(@item.id)
    provider = mock
    provider.stubs(:create_session).returns(session_id: "new_sess", accounts: [])
    authorizing.stubs(:enable_banking_provider).returns(provider)
    session_saved = Concurrent::CountDownLatch.new(1)
    authorization_pid = Concurrent::IVar.new
    locked = Concurrent::CountDownLatch.new(1)
    # Pause once the session is stored, before the transaction that writes
    # the request.
    authorizing.define_singleton_method(:update!) do |attributes|
      super(attributes).tap do
        next unless attributes.key?(:session_id)

        session_saved.count_down
        raise "the other connection never took the item lock" unless locked.wait(5)
      end
    end

    authorization = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        authorization_pid.set(ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()"))
        authorizing.complete_authorization(code: "code")
      end
    end
    # Another request's sync_later: it takes the item lock at that point, and
    # creates its sync only once the authorization is blocked on that lock.
    other = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        raise "the authorization never stored the session" unless session_saved.wait(5)

        Sync.transaction do
          EnableBankingItem.find(@item.id).lock!
          locked.count_down
          wait_until_blocked(authorization_pid.value(5))
          @item.syncs.create!(status: "syncing")
        end
      end
    end
    sync = other.value
    authorization.value

    # That sync's importer could have read the request before it committed.
    # Once it finishes, the post-sync check must still queue a follow-up.
    sync.update!(status: "completed", completed_at: Time.current)
    assert_operator @item.reload.full_history_fetch_requested_at, :>, sync.created_at,
                    "the request predates a sync that may not have seen it"
    assert_difference -> { @item.syncs.count }, 1 do
      EnableBankingItem::Syncer.new(@item).perform_post_sync
    end
  end

  test "two authorizations that import distinct accounts both complete" do
    first = authorizing_with(uid: "acct_first")
    second = authorizing_with(uid: "acct_second")
    second_pid = Concurrent::IVar.new
    second_done = Concurrent::CountDownLatch.new(1)
    blocked = method(:blocked?)
    wait_until = method(:wait_until)
    first_imported = Concurrent::CountDownLatch.new(1)
    # The first authorization pauses after inserting its account, until the
    # second has either finished or is waiting on it. Each insert's foreign key
    # check holds KEY SHARE on the item row, so a lock that conflicts with KEY
    # SHARE (FOR UPDATE) would leave each waiting for the other.
    first.define_singleton_method(:import_accounts_from_session) do |accounts|
      super(accounts).tap do
        first_imported.count_down
        wait_until.call("the second authorization neither finished nor waited") do
          second_done.count.zero? || blocked.call(second_pid.value(5))
        end
      end
    end

    one = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        first.complete_authorization(code: "code")
      end
    end
    two = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_pid.set(ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()"))
        raise "the first authorization never imported its account" unless first_imported.wait(5)

        second.complete_authorization(code: "code")
      ensure
        second_done.count_down
      end
    end

    assert_empty thread_errors(one, two)
    assert_equal %w[acct_first acct_second],
                 EnableBankingAccount.where(enable_banking_item_id: @item.id).order(:uid).pluck(:uid)
    assert_not_nil @item.reload.full_history_fetch_requested_at
  end

  test "a second authorization waits while the first holds the item lock" do
    first = authorizing_with(uid: "acct_first")
    second = authorizing_with(uid: "acct_second")
    second_pid = Concurrent::IVar.new
    wait_until_blocked = method(:wait_until_blocked)
    first_locked = Concurrent::CountDownLatch.new(1)
    first_requested_at = Concurrent::IVar.new
    # The first authorization pauses with the item lock held, just before it
    # writes the request.
    first.define_singleton_method(:update!) do |attributes|
      if attributes.key?(:full_history_fetch_requested_at)
        first_requested_at.set(attributes[:full_history_fetch_requested_at])
        first_locked.count_down
        wait_until_blocked.call(second_pid.value(5))
      end
      super(attributes)
    end

    one = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        first.complete_authorization(code: "code")
      end
    end
    two = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_pid.set(ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()"))
        raise "the first authorization never took the item lock" unless first_locked.wait(5)

        second.complete_authorization(code: "code")
      end
    end

    assert_empty thread_errors(one, two)
    assert_operator @item.reload.full_history_fetch_requested_at, :>, first_requested_at.value,
                    "the second request was not written after the first"
  end

  test "a sync_later waiting on the account import's KEY SHARE lock creates its sync after the request" do
    authorizing = authorizing_with(uid: "acct_new")
    other_pid = Concurrent::IVar.new
    wait_until_blocked = method(:wait_until_blocked)
    imported = Concurrent::CountDownLatch.new(1)
    # The authorization pauses after inserting the account, until sync_later's
    # FOR UPDATE waits on its KEY SHARE lock, then takes the item lock itself.
    authorizing.define_singleton_method(:import_accounts_from_session) do |accounts|
      super(accounts).tap do
        imported.count_down
        wait_until_blocked.call(other_pid.value(5))
      end
    end

    authorization = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        authorizing.complete_authorization(code: "code")
      end
    end
    other = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        other_pid.set(ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()"))
        raise "the authorization never imported its account" unless imported.wait(5)

        EnableBankingItem.find(@item.id).sync_later
      end
    end

    assert_empty thread_errors(authorization, other)
    sync = @item.syncs.ordered.first
    assert_operator sync.created_at, :>, @item.reload.full_history_fetch_requested_at
  end

  test "deleting the item while it is re-authorized does not deadlock" do
    EnableBankingAccount.create!(enable_banking_item: @item, uid: "acct_stored", name: "Stored", currency: "EUR")
    authorizing = authorizing_with(uid: "acct_stored")
    deleting = EnableBankingItem.find(@item.id)
    authorization_pid = Concurrent::IVar.new
    wait_until_blocked = method(:wait_until_blocked)
    accounts_deleted = Concurrent::CountDownLatch.new(1)
    # The delete removes the item's account rows first (dependent: :destroy),
    # then pauses before deleting the item row until the authorization waits
    # on it.
    deleting.define_singleton_method(:destroy_row) do
      accounts_deleted.count_down
      wait_until_blocked.call(authorization_pid.value(5))
      super()
    end

    deletion = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        deleting.destroy!
      end
    end
    authorization = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        authorization_pid.set(ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()"))
        raise "the delete never removed the accounts" unless accounts_deleted.wait(5)

        authorizing.complete_authorization(code: "code")
      end
    end

    assert_empty thread_errors(deletion)
    # The authorization then finds the item gone.
    assert_empty thread_errors(authorization).grep(/Deadlocked/)
    assert_not EnableBankingItem.exists?(@item.id), "the item was not deleted"
  end

  private

    def authorizing_with(uid:)
      item = EnableBankingItem.find(@item.id)
      provider = mock
      provider.stubs(:create_session).returns(
        session_id: "new_sess", accounts: [ { uid: uid, name: "Account #{uid}", currency: "EUR" } ]
      )
      item.stubs(:enable_banking_provider).returns(provider)
      item
    end

    def thread_errors(*threads)
      threads.filter_map do |thread|
        thread.value
        nil
      rescue => e
        "#{e.class}: #{e.message}"
      end
    end

    def blocked?(pid)
      ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").to_i.positive?
    end

    def wait_until(message)
      deadline = 5.seconds.from_now
      until yield
        raise message if Time.current > deadline
        sleep 0.01
      end
    end

    def wait_until_blocked(pid)
      wait_until("the other connection never waited on a lock") { blocked?(pid) }
    end
end
