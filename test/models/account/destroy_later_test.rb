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

  # The relink cleanup in the Coinbase, Enable Banking and SimpleFIN controllers
  # calls destroy_later inside its own transaction, with its own rescue. The push
  # only happens once that outer transaction commits, so the error escapes past
  # the caller's rescue (unchanged); the account must still be restored.
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
end
