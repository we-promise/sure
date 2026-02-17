# frozen_string_literal: true

Rails.configuration.x.assistant ||= ActiveSupport::OrderedOptions.new

begin
  raw_config = Rails.application.config_for(:assistant)
rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError => e
  Rails.logger.warn("Assistant config not loaded: #{e.class} - #{e.message}")
  raw_config = {}
end

assistant_config = raw_config.deep_symbolize_keys

Rails.configuration.x.assistant.instructions = assistant_config.fetch(:instructions, {})
