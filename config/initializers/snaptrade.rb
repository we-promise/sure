Rails.application.configure do
  config.x.snaptrade ||= ActiveSupport::OrderedOptions.new
  config.x.snaptrade.oauth_client_id = ENV["SNAPTRADE_OAUTH_CLIENT_ID"].presence ||
                                      Rails.application.credentials.dig(:snaptrade, :oauth_client_id)
  config.x.snaptrade.oauth_client_secret = ENV["SNAPTRADE_OAUTH_CLIENT_SECRET"].presence ||
                                          Rails.application.credentials.dig(:snaptrade, :oauth_client_secret)
end
