# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

rails_env = ENV.fetch("RAILS_ENV", "development")

# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# to prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 3 }
threads threads_count, threads_count

if rails_env == "production"
  # If you are running more than 1 thread per process, the workers count
  # should be equal to the number of processors (CPU cores) in production.
  #
  # It defaults to 1 because it's impossible to reliably detect how many
  # CPU cores are available. Make sure to set the `WEB_CONCURRENCY` environment
  # variable to match the number of processors.
  workers_count = Integer(ENV.fetch("WEB_CONCURRENCY") { 1 })
  workers workers_count if workers_count > 1

  preload_app!
end

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT") { 3000 }

# Specifies the `environment` that Puma will run in.
environment rails_env

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

if rails_env == "development"
  # Specifies a very generous `worker_timeout` so that the worker
  # isn't killed by Puma when suspended by a debugger.
  worker_timeout 3600
end

# Set up SIGUSR1 handler in worker processes to dump settings
# This runs after Puma sets up its worker, so it only affects individual workers
# The master process can still use SIGUSR1 for phased restarts
on_worker_boot do
  Signal.trap("USR1") do
    Thread.new do
      begin
        Rails.logger.info "=" * 80
        Rails.logger.info "SIGUSR1 received in Puma worker - Dumping application settings"
        Rails.logger.info "Process: #{$PROGRAM_NAME} (PID: #{Process.pid})"
        Rails.logger.info "=" * 80

        # Get all declared fields from Setting model
        declared_fields = Setting.singleton_class.instance_methods(false)
          .map(&:to_s)
          .reject { |m| m.end_with?("=") || m.start_with?("raw_") || %w[[] []= key? delete dynamic_keys validate_onboarding_state! validate_openai_config!].include?(m) }
          .sort

        # Get all dynamic fields
        dynamic_fields = Setting.dynamic_keys.sort

        # Helper to mask sensitive values
        mask_value = lambda do |field_name, value|
          return nil if value.nil?

          sensitive = [ /key/i, /token/i, /secret/i, /password/i, /api/i, /credentials?/i, /auth/i ]
          is_sensitive = sensitive.any? { |pattern| field_name.match?(pattern) }

          if is_sensitive && value.present?
            case value
            when String
              value.length <= 4 ? "[MASKED]" : "#{value[0..3]}#{'*' * [ value.length - 4, 8 ].min}"
            when TrueClass, FalseClass
              value
            else
              "[MASKED]"
            end
          else
            value
          end
        end

        # Dump declared fields
        unless declared_fields.empty?
          Rails.logger.info "\n--- Declared Settings ---"
          declared_fields.each do |field|
            value = Setting.public_send(field)
            masked_value = mask_value.call(field, value)
            Rails.logger.info "  #{field}: #{masked_value.inspect}"
          end
        end

        # Dump dynamic fields
        unless dynamic_fields.empty?
          Rails.logger.info "\n--- Dynamic Settings ---"
          dynamic_fields.each do |field|
            value = Setting[field]
            masked_value = mask_value.call(field, value)
            Rails.logger.info "  #{field}: #{masked_value.inspect}"
          end
        end

        Rails.logger.info "\n" + "=" * 80
        Rails.logger.info "Settings dump complete (#{declared_fields.size} declared, #{dynamic_fields.size} dynamic)"
        Rails.logger.info "=" * 80
      rescue => e
        Rails.logger.error "Error dumping settings: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end
  end
end
