require "test_helper"

class Account::DestroyLaterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:depository)
  end

  test "marks the account pending deletion and enqueues its destruction" do
    assert_enqueued_with(job: DestroyJob, args: [ @account ]) do
      assert @account.destroy_later
    end

    assert @account.reload.pending_deletion?
  end

  # The adapter is stubbed rather than perform_later, so ActiveJob's own
  # enqueue path decides what destroy_later sees. This is what an unreachable
  # Redis looks like through the Sidekiq adapter: the push raises straight out.
  test "restores the prior status and re-raises when the enqueue raises" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { @account.destroy_later }

    assert_equal "active", @account.reload.status
    assert_includes Account.visible, @account
  end

  # An adapter raising ActiveJob::EnqueueError makes perform_later return false
  # instead of raising.
  test "returns false and restores the prior status when the enqueue is rejected" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "rejected")

    assert_equal false, @account.destroy_later

    assert_equal "active", @account.reload.status
  end

  test "restores a disabled account to disabled when the enqueue fails" do
    @account.update_column(:status, "disabled")
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { @account.destroy_later }

    assert_equal "disabled", @account.reload.status
  end

  test "restores a draft account to draft when the enqueue fails" do
    @account.update_column(:status, "draft")
    DestroyJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "rejected")

    assert_equal false, @account.destroy_later

    assert_equal "draft", @account.reload.status
  end

  # A caller that wraps destroy_later in its own transaction, with its own
  # rescue, does not see the error there: the push only happens once that outer
  # transaction commits, so the error leaves from the commit. The relink cleanup
  # in the provider controllers calls destroy_later after its transaction for
  # this reason. Whoever calls it, the account must still be restored.
  test "an enqueue failure after an outer transaction commits restores the status" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")
    rescued_inside = false

    assert_raises(RedisClient::CannotConnectError) do
      Account.transaction do
        @account.destroy_later
      rescue StandardError
        rescued_inside = true
      end
    end

    assert_not rescued_inside
    assert_equal "active", @account.reload.status
  end

  test "a rolled-back outer transaction leaves the status and the queue untouched" do
    assert_no_enqueued_jobs(only: DestroyJob) do
      Account.transaction do
        @account.destroy_later
        raise ActiveRecord::Rollback
      end
    end

    assert_equal "active", @account.reload.status
  end

  # The restore puts back only what this call changed. An account already
  # pending deletion was marked by an earlier request, so a second call must not
  # clear that mark.
  test "an account already pending deletion still raises and stays pending deletion" do
    @account.update_column(:status, "pending_deletion")
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(AASM::InvalidTransition) { @account.destroy_later }

    assert_equal "pending_deletion", @account.reload.status
  end

  # A double submit loads the account twice before either request commits. The
  # second copy still holds the old status, so without a reload it would pass
  # the guard, and its failed enqueue would put back "active" while the first
  # request's DestroyJob is queued.
  test "a stale copy cannot put back a status another request already marked" do
    stale = Account.find(@account.id)
    assert @account.destroy_later
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(AASM::InvalidTransition) { stale.destroy_later }

    assert_equal "pending_deletion", @account.reload.status
  end

  # The status to restore is read after the reload, so a stale copy puts back
  # what the row held when it was marked, not what the copy was loaded with.
  test "a stale copy restores the status the row held when it was marked" do
    stale = Account.find(@account.id)
    @account.disable!
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    assert_raises(RedisClient::CannotConnectError) { stale.destroy_later }

    assert_equal "disabled", @account.reload.status
  end

  # The row lock covers only the mark; the push runs after commit. A request
  # blocked on that lock (toggle_active calling disable! on a copy loaded as
  # active) writes its status once the mark commits. A failed enqueue must not
  # then put back the status captured before the mark over that newer write.
  test "a failed enqueue does not overwrite a status another request set after the mark" do
    [
      [ RedisClient::CannotConnectError, ->(account) { assert_raises(RedisClient::CannotConnectError) { account.destroy_later } } ],
      [ ActiveJob::EnqueueError, ->(account) { assert_equal false, account.destroy_later } ]
    ].each_with_object({}) do |(error, call), statuses|
      @account.update_column(:status, "active")
      account = Account.find(@account.id)
      DestroyJob.queue_adapter.unstub(:enqueue)
      DestroyJob.queue_adapter.stubs(:enqueue).with do |*|
        Account.where(id: account.id).update_all(status: "disabled")
        true
      end.raises(error, "enqueue failed")

      call.call(account)

      statuses[error.name] = @account.reload.status
    end.then do |statuses|
      assert_equal({ "RedisClient::CannotConnectError" => "disabled", "ActiveJob::EnqueueError" => "disabled" }, statuses)
    end
  end
end
