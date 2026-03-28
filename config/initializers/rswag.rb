if defined?(Rswag::Ui) && Rails.env.development?
  Rswag::Ui.configure do |c|
    c.openapi_endpoint "/api-docs/openapi.yaml", "Sure API V1"
  end
end

if defined?(Rswag::Api) && Rails.env.development?
  Rswag::Api.configure do |c|
    c.openapi_root = Rails.root.join("docs", "api").to_s
  end
end
