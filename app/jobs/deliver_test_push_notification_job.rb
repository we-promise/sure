# frozen_string_literal: true

class DeliverTestPushNotificationJob < ApplicationJob
  queue_as :scheduled
  # The request is already in the shared cache; no uncommitted database row is
  # needed by the worker. Surface enqueue failures while the request is handled.
  self.enqueue_after_transaction_commit = false
  sidekiq_options lock: :until_executed, on_conflict: :log

  retry_on Apns::Client::TransientError, wait: :polynomially_longer, attempts: 5 do |job, _error|
    arguments = job.arguments.first.symbolize_keys
    if (user = User.find_by(id: arguments[:user_id]))
      PushNotificationTest.new(user).record(arguments[:request_id], arguments[:push_subscription_id], :failed)
    end
  end
  discard_on ActiveRecord::RecordNotFound

  def perform(user_id:, request_id:, push_subscription_id:)
    user = User.find(user_id)
    PushNotificationTest.new(user).deliver(request_id: request_id, push_subscription_id: push_subscription_id)
  end
end
