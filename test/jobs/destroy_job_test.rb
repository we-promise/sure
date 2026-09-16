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

  test "ordinary failures without a deletion flag retain their existing behavior" do
    model = Object.new
    model.expects(:destroy).raises(IOError, "ordinary failure")
    model.expects(:update!).never

    assert_nil DestroyJob.perform_now(model)
  end

  test "a destroy returning false does not change existing recovery semantics" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.expects(:destroy).returns(false)
    model.expects(:update!).never

    assert_equal false, DestroyJob.perform_now(model)
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

  test "a refused legacy destroy cannot reset its lifecycle state" do
    [ Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged,
      Provider::AccountData::LegacyWriterFence::InvalidSource ].each do |error_class|
      model = mock("refused legacy deletion")
      failure = error_class.new("refused")
      model.expects(:destroy).raises(failure)
      model.expects(:update!).never

      assert_same failure, assert_raises(error_class) { DestroyJob.perform_now(model) }
    end
  end
end
