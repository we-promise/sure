# frozen_string_literal: true

Rails.configuration.x.wise.tap do |wise|
  wise.base_url = ENV.fetch("WISE_BASE_URL", "https://api.wise.com")
  wise.include_pending = ENV.fetch("WISE_INCLUDE_PENDING", "true") == "true"
end
