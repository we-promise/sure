Rails.application.configure do
  truthy = %w[1 true yes on]

  config.x.simplefin ||= ActiveSupport::OrderedOptions.new
  config.x.simplefin.include_pending = truthy.include?(ENV["SIMPLEFIN_INCLUDE_PENDING"].to_s.strip.downcase)
  config.x.simplefin.debug_raw = truthy.include?(ENV["SIMPLEFIN_DEBUG_RAW"].to_s.strip.downcase)
end
