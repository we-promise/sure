Rails.application.configure do
  config.x.snaptrade ||= ActiveSupport::OrderedOptions.new
  config.x.snaptrade.oauth_client_id = ENV["SNAPTRADE_OAUTH_CLIENT_ID"].presence ||
                                      Rails.application.credentials.dig(:snaptrade, :oauth_client_id)
end
