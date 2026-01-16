# frozen_string_literal: true

# DatabaseMirrorJob - Background job for mirroring database writes
#
# This job handles the actual mirroring of database operations to an external
# PostgreSQL database. It runs at high priority to ensure timely replication.
#
# Retries are configured with exponential backoff to handle temporary
# connection failures while ensuring data durability.
#
class DatabaseMirrorJob < ApplicationJob
  queue_as :high_priority

  # Retry on connection-related errors with exponential backoff
  # Max 10 attempts over ~17 hours total
  retry_on PG::ConnectionBad, wait: :polynomially_longer, attempts: 10
  retry_on PG::UnableToSend, wait: :polynomially_longer, attempts: 10
  retry_on ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 10
  retry_on ActiveRecord::StatementInvalid, wait: :polynomially_longer, attempts: 5

  # Discard jobs that fail after all retries to prevent infinite loops
  discard_on ActiveJob::DeserializationError

  def perform(operation:, model_class:, primary_key:, attributes:)
    return unless ENV["DATABASE_MIRROR_ENABLED"] == "true"

    service = DatabaseMirrorService.new

    case operation.to_sym
    when :create
      service.mirror_create(model_class, primary_key, attributes)
    when :update
      service.mirror_update(model_class, primary_key, attributes)
    when :destroy
      service.mirror_destroy(model_class, primary_key)
    else
      Rails.logger.error("[DatabaseMirrorJob] Unknown operation: #{operation}")
    end
  rescue => e
    Rails.logger.error("[DatabaseMirrorJob] Failed to mirror #{operation} for #{model_class}##{primary_key}: #{e.class} - #{e.message}")
    raise # Re-raise to trigger retry
  end
end
