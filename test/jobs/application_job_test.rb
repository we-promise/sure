require "test_helper"

class ApplicationJobTest < ActiveJob::TestCase
  # Throwaway subclass used only to exercise ApplicationJob's enqueue policy
  # without depending on any real job's side effects.
  class CanaryJob < ApplicationJob
    def perform; end
  end

  test "defers enqueue until the surrounding transaction commits" do
    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      CanaryJob.perform_later
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == CanaryJob }
    end

    assert_not enqueued_mid_transaction, "job was enqueued before the transaction committed"
    assert_enqueued_with job: CanaryJob
  end

  test "drops the enqueue when the surrounding transaction rolls back" do
    assert_no_enqueued_jobs do
      ActiveRecord::Base.transaction do
        CanaryJob.perform_later
        raise ActiveRecord::Rollback
      end
    end
  end

  test "enqueues immediately when there is no surrounding transaction" do
    assert_enqueued_with job: CanaryJob do
      CanaryJob.perform_later
    end
  end
end
