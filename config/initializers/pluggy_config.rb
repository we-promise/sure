# frozen_string_literal: true

Rails.application.configure do
  config.x.pluggy = OpenStruct.new(
    base_url: ENV.fetch("PLUGGY_API_BASE_URL", "https://api.pluggy.ai"),
    include_pending: ENV.fetch("PLUGGY_INCLUDE_PENDING", "1") != "0",
    include_sandbox: Rails.env.development? || Rails.env.test?
  )
end
