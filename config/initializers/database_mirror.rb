# frozen_string_literal: true

# Database Mirror Initializer
#
# Configures and validates the database mirror feature.
# The mirror database schema is only initialized on first boot if it's empty.
#
if ENV["DATABASE_MIRROR_ENABLED"] == "true"
  Rails.application.config.after_initialize do
    # Validate required configuration
    required_vars = %w[MIRROR_DB_HOST MIRROR_DB_NAME MIRROR_DB_USER MIRROR_DB_PASSWORD]
    missing_vars = required_vars.select { |var| ENV[var].blank? }

    if missing_vars.any?
      Rails.logger.error(
        "[DatabaseMirror] Missing required environment variables: #{missing_vars.join(', ')}. " \
        "Database mirroring is DISABLED."
      )
      # Disable mirroring if configuration is incomplete
      ENV["DATABASE_MIRROR_ENABLED"] = "false"
    else
      Rails.logger.info("[DatabaseMirror] Database mirroring is enabled")
      Rails.logger.info("[DatabaseMirror] Mirror DB: #{ENV['MIRROR_DB_HOST']}:#{ENV.fetch('MIRROR_DB_PORT', '5432')}/#{ENV['MIRROR_DB_NAME']}")

      # Initialize schema in background to avoid blocking app startup
      # Only runs if mirror database is empty
      Thread.new do
        sleep 5 # Wait for app to fully initialize

        begin
          service = DatabaseMirrorService.new
          if service.database_empty?
            Rails.logger.info("[DatabaseMirror] Initializing schema in mirror database...")
            service.initialize_schema_if_empty!
            Rails.logger.info("[DatabaseMirror] Schema initialization complete")
          else
            Rails.logger.info("[DatabaseMirror] Mirror database already contains data, skipping schema initialization")
          end
        rescue => e
          Rails.logger.error("[DatabaseMirror] Failed to initialize mirror database: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.first(10).join("\n"))
        end
      end
    end
  end
end
