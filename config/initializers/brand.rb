Rails.application.configure do
  config.x.brand_name = ENV.fetch("BRAND_NAME", "Sure")
  config.x.brand_plus = ENV.fetch("BRAND_PLUS", "#{config.x.brand_name}+")
end
