# frozen_string_literal: true

require "timeout"

module SettingsSignalDumper
  SENSITIVE_PATTERNS = [
    /key/i,
    /token/i,
    /secret/i,
    /password/i,
    /api/i,
    /credentials?/i,
    /auth/i
  ].freeze

  SETTINGS_QUERY_TIMEOUT = 5

  def self.install_usr1_trap(process_label:, logger: nil)
    logger ||= Rails.logger

    Signal.trap("USR1") do
      Thread.new do
        dump_settings(process_label: process_label, logger: logger)
      end
    end

    logger.info "Signal handler initialized for #{process_label} (SIGUSR1 -> dump settings)"
  end

  def self.dump_settings(process_label:, logger: nil)
    logger ||= Rails.logger

    declared_fields = declared_setting_fields
    dynamic_fields = dynamic_setting_fields(logger: logger)

    logger.info "=" * 80
    logger.info "SIGUSR1 received in #{process_label} - Dumping application settings"
    logger.info "Process: #{$PROGRAM_NAME} (PID: #{Process.pid})"
    logger.info "=" * 80

    unless declared_fields.empty?
      logger.info "\n--- Declared Settings ---"
      declared_fields.each do |field|
        value = Setting.public_send(field)
        masked_value = mask_value(field, value)
        logger.info "  #{field}: #{masked_value.inspect}"
      end
    end

    unless dynamic_fields.empty?
      logger.info "\n--- Dynamic Settings ---"
      dynamic_fields.each do |field|
        value = Setting[field]
        masked_value = mask_value(field, value)
        logger.info "  #{field}: #{masked_value.inspect}"
      end
    end

    logger.info "\n" + "=" * 80
    logger.info "Settings dump complete (#{declared_fields.size} declared, #{dynamic_fields.size} dynamic)"
    logger.info "=" * 80
  rescue => e
    logger.error "Error dumping settings: #{e.class} - #{e.message}"
    logger.error e.backtrace.join("\n")
  end

  def self.declared_setting_fields
    Setting.singleton_class.instance_methods(false)
      .map(&:to_s)
      .reject do |method_name|
        method_name.end_with?("=") ||
          method_name.start_with?("raw_") ||
          %w[[] []= key? delete dynamic_keys validate_onboarding_state! validate_openai_config!].include?(method_name)
      end
      .sort
  end

  def self.dynamic_setting_fields(logger: nil)
    logger ||= Rails.logger

    Timeout.timeout(SETTINGS_QUERY_TIMEOUT) do
      Setting.dynamic_keys.sort
    end
  rescue Timeout::Error
    logger.error "Timed out fetching dynamic settings after #{SETTINGS_QUERY_TIMEOUT} seconds"
    []
  end

  def self.mask_value(field_name, value)
    return nil if value.nil?

    is_sensitive = SENSITIVE_PATTERNS.any? { |pattern| field_name.match?(pattern) }

    if is_sensitive
      case value
      when String
        if value.empty?
          "[EMPTY]"
        elsif value.length <= 4
          "[MASKED]"
        else
          "#{value[0..3]}#{'*' * [ value.length - 4, 8 ].min}"
        end
      when TrueClass, FalseClass
        value
      else
        "[MASKED]"
      end
    else
      value
    end
  end
end
