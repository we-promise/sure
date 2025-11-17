# Signal handlers for web and worker processes
#
# SIGUSR1: Dump current settings array values (masked) to Rails.log
Rails.application.config.after_initialize do
  # Helper lambda to mask sensitive values
  mask_sensitive_value = lambda do |field_name, value|
    return nil if value.nil?

    # Check if field name contains sensitive patterns
    sensitive_patterns = [
      /key/i,
      /token/i,
      /secret/i,
      /password/i,
      /api/i,
      /credentials?/i,
      /auth/i
    ]

    is_sensitive = sensitive_patterns.any? { |pattern| field_name.match?(pattern) }

    if is_sensitive && value.present?
      case value
      when String
        # Show first 4 chars and mask the rest
        if value.length <= 4
          "[MASKED]"
        else
          "#{value[0..3]}#{'*' * [value.length - 4, 8].min}"
        end
      when TrueClass, FalseClass
        value # Don't mask booleans
      else
        "[MASKED]"
      end
    else
      value
    end
  end

  Signal.trap("USR1") do
    # Run in a new thread to avoid signal handler restrictions
    Thread.new do
      begin
        Rails.logger.info "=" * 80
        Rails.logger.info "SIGUSR1 received - Dumping application settings"
        Rails.logger.info "Process: #{$PROGRAM_NAME} (PID: #{Process.pid})"
        Rails.logger.info "=" * 80

        # Get all declared fields from Setting model
        # Find all field methods (getters) defined on the Setting singleton class
        declared_fields = Setting.singleton_class.instance_methods(false)
          .map(&:to_s)
          .reject { |m| m.end_with?("=") || m.start_with?("raw_") || %w[[] []= key? delete dynamic_keys validate_onboarding_state! validate_openai_config!].include?(m) }
          .sort

        # Get all dynamic fields
        dynamic_fields = Setting.dynamic_keys.sort

        # Dump declared fields
        unless declared_fields.empty?
          Rails.logger.info "\n--- Declared Settings ---"
          declared_fields.each do |field|
            value = Setting.public_send(field)
            masked_value = mask_sensitive_value.call(field, value)
            Rails.logger.info "  #{field}: #{masked_value.inspect}"
          end
        end

        # Dump dynamic fields
        unless dynamic_fields.empty?
          Rails.logger.info "\n--- Dynamic Settings ---"
          dynamic_fields.each do |field|
            value = Setting[field]
            masked_value = mask_sensitive_value.call(field, value)
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

  Rails.logger.info "Signal handlers initialized (SIGUSR1 -> dump settings)"
end
