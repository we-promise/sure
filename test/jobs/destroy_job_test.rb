require "test_helper"
require "ostruct"

class DestroyJobTest < ActiveJob::TestCase
  test "destroys the model" do
    model = mock
    model.expects(:destroy).once

    DestroyJob.perform_now(model)
  end

  test "resets scheduled_for_deletion when the destroy fails" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.stubs(:destroy).raises(ActiveRecord::RecordNotDestroyed.new("nope"))
    model.expects(:update!).with(scheduled_for_deletion: false).once

    DestroyJob.perform_now(model)
  end

  test "a provider item's failed destroy still resets scheduled_for_deletion" do
    item = plaid_items(:one)
    item.update_column(:scheduled_for_deletion, true)
    item.stubs(:destroy).raises(StandardError, "destroy failed")

    DestroyJob.perform_now(item)

    assert_not item.reload.scheduled_for_deletion?
  end

  test "an account whose destroy raises is left disabled, not pending_deletion" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    assert_no_difference "Account.count" do
      DestroyJob.perform_now(account)
    end

    assert_equal "disabled", account.reload.status
  end

  test "an account whose destroy succeeds is removed" do
    account = accounts(:depository)
    account.mark_for_deletion!

    assert_difference "Account.count", -1 do
      DestroyJob.perform_now(account)
    end
  end

  test "inherits the deferred-enqueue policy from ApplicationJob" do
    account = accounts(:depository)
    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      DestroyJob.perform_later(account)
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == DestroyJob }
    end

    assert_not enqueued_mid_transaction, "DestroyJob enqueued before the transaction committed"
    assert_enqueued_with job: DestroyJob
  end
end
