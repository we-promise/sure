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

# Rswag's UI middleware returns its own CSP (which allows the inline Swagger UI
# bootstrap script) under a mixed-case header name. Rails' CSP middleware looks
# for the lowercase Rack 3 name, misses it and adds the app policy as a second
# header, which blocks that script and leaves /api-docs blank. Normalizing the
# header names lets Rails see the existing policy and keep it.
if defined?(Rswag::Ui) && Rails.env.development?
  require "rswag/ui/middleware"

  Rswag::Ui::Middleware.prepend(Module.new do
    def call(env)
      status, headers, body = super
      [ status, Rack::Headers.new.merge!(headers), body ]
    end
  end)
end
