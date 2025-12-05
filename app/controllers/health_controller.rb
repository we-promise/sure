class HealthController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!
  skip_before_action :set_request_details
  skip_before_action :set_sentry_user
  skip_before_action :verify_self_host_config

  # Silence logging for liveliness endpoint
  around_action :silence_logger, only: :liveliness

  def healthcheck
    checks = {
      database: check_database,
      redis: check_redis
    }

    all_healthy = checks.values.all?

    status = all_healthy ? :ok : :service_unavailable
    render json: checks, status: status
  end

  def liveliness
    head :ok
  end

  private

    def check_database
      ActiveRecord::Base.connection.execute("SELECT 1")
      true
    rescue StandardError => e
      Rails.logger.error("Database health check failed: #{e.message}")
      false
    end

    def check_redis
      Sidekiq.redis(&:ping)
      true
    rescue StandardError => e
      Rails.logger.error("Redis health check failed: #{e.message}")
      false
    end

    def silence_logger
      old_level = Rails.logger.level
      Rails.logger.level = Logger::UNKNOWN
      yield
    ensure
      Rails.logger.level = old_level
    end
end
