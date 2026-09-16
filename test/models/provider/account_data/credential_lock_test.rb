require "test_helper"

class Provider::AccountData::CredentialLockTest < ActiveSupport::TestCase
  Store = Provider::AccountData::CredentialStore
  CONNECTION_ID = "12345678-1234-1234-1234-123456789abc".freeze

  teardown do
    ActiveSupport::IsolatedExecutionState.delete(Store::LOCK_CONTEXT)
  end

  test "uncertain acquisition disconnects the session and preserves the transport error" do
    with_database do |database|
      error = IOError.new("lost acquisition response")
      database.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).raises(error)
      database.expects(:disconnect!).once
      assert_same error, assert_raises(IOError) { lock { flunk "unknown acquisition cannot enter" } }
      assert_nil ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
    end
  end

  test "failed release disconnects and reports lost ownership" do
    with_database do |database|
      database.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).returns(true)
      database.expects(:select_value).with(regexp_matches(/pg_advisory_unlock/)).returns(false)
      database.expects(:disconnect!).once
      assert_raises(Store::Busy) { lock { :completed } }
      assert_nil ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
    end
  end

  test "release and disconnect failures cannot replace the original operation failure" do
    with_database do |database|
      error = IOError.new("original operation")
      database.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).returns(true)
      database.expects(:select_value).with(regexp_matches(/pg_advisory_unlock/)).raises(IOError, "release failed")
      database.expects(:disconnect!).raises(IOError, "disconnect failed")
      assert_same error, assert_raises(IOError) { lock { raise error } }
      assert_nil ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
    end
  end

  test "a definite lock conflict does not unlock or disconnect someone else's session" do
    with_database do |database|
      database.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).returns(false)
      database.expects(:select_value).with(regexp_matches(/pg_advisory_unlock/)).never
      database.expects(:disconnect!).never
      assert_raises(Store::Busy) { lock { flunk "must not enter" } }
      assert_nil ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
    end
  end

  test "nested operations cannot replace an outer credential owner or clear its context" do
    with_database do |database|
      database.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).once.returns(true)
      database.expects(:select_value).with(regexp_matches(/pg_advisory_unlock/)).once.returns(true)
      assert_equal :outer, lock {
        assert_raises(Store::Busy) { lock { flunk "must not enter" } }
        assert_equal CONNECTION_ID, ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
        :outer
      }
      assert_nil ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
    end
  end

  test "an interruption releases the actual acquired permit before propagating" do
    with_database do |database|
      database.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).returns(true)
      database.expects(:select_value).with(regexp_matches(/pg_advisory_unlock/)).returns(true)
      assert_raises(Interrupt) { lock { raise Interrupt } }
      assert_nil ActiveSupport::IsolatedExecutionState[Store::LOCK_CONTEXT]
    end
  end

  private
    def with_database
      database = mock("credential database session")
      database.stubs(:open_transactions).returns(0)
      database.stubs(:quote).with("provider_credentials:#{CONNECTION_ID}").returns("'provider_credentials:#{CONNECTION_ID}'")
      ProviderConnection.connection_pool.stubs(:with_connection).yields(database)
      yield database
    end

    def lock(&block)
      Store.with_connection_lock(connection_id: CONNECTION_ID, &block)
    end
end
