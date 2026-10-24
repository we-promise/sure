require "digest"

class Provider::Brandfetch < Provider
  Usage = Data.define(:used, :quota) do
    def utilization
      quota.positive? ? used.fdiv(quota) * 100 : nil
    end

    def bar_percentage
      utilization&.clamp(0, 100)
    end
  end

  def self.configured_api_key
    ENV["BRAND_FETCH_API_KEY"].presence || Setting.brand_fetch_api_key
  end

  def initialize(api_key)
    @api_key = api_key
  end

  # Viewer reports API credits, not Logo CDN requests. The endpoint is free.
  # Cache by credential digest so changing a key cannot reuse another key's data.
  def usage
    with_provider_response do
      Rails.cache.fetch("brandfetch/usage/v1/#{Digest::SHA256.hexdigest(@api_key)}", expires_in: 5.minutes) do
        response = Faraday.get("https://api.brandfetch.io/v2/viewer") do |request|
          request.headers["Authorization"] = "Bearer #{@api_key}"
          request.headers["Accept"] = "application/json"
          request.options.timeout = 5
          request.options.open_timeout = 2
        end
        raise Error, "Brandfetch usage request failed" unless response.success?

        body = JSON.parse(response.body)
        used = body.dig("usage", "used")
        quota = body.dig("usage", "quota")
        unless body["type"] == "api-key" && used.is_a?(Integer) && quota.is_a?(Integer) && used >= 0 && quota >= 0
          raise Error, "Brandfetch usage is unavailable"
        end

        Usage.new(used: used, quota: quota)
      end
    end
  end

  private
    # Do not expose upstream bodies, request headers or credentials to the UI.
    def default_error_transformer(_error)
      Error.new("Brandfetch usage is unavailable")
    end
end
