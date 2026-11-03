require "uri"

# Resolves the outbound HTTP proxy from the conventional HTTPS_PROXY/HTTP_PROXY
# and NO_PROXY environment variables.
class HttpProxy
  class << self
    # Returns the configured proxy URI for the given scheme and host, or nil
    # when no proxy applies. With fallback, an HTTPS request also uses
    # HTTP_PROXY when HTTPS_PROXY is not set.
    def resolve(scheme:, host:, fallback: false)
      env_key = scheme.to_s == "https" ? "HTTPS_PROXY" : "HTTP_PROXY"
      env_keys = [ env_key ]
      env_keys << "HTTP_PROXY" if fallback && env_key == "HTTPS_PROXY"

      proxy_url = env_keys.filter_map { |key| ENV[key].presence || ENV[key.downcase].presence }.first
      return if proxy_url.blank?
      return if bypassed?(host, ENV["NO_PROXY"].presence || ENV["no_proxy"])

      URI(proxy_url)
    end

    def bypassed?(host, no_proxy)
      return false if no_proxy.blank?

      patterns = no_proxy.split(",").map { |pattern| pattern.strip.downcase }
      return true if patterns.include?("*")

      host = host.to_s.downcase
      patterns.any? do |pattern|
        pattern = pattern.delete_prefix(".")
        next false if pattern.empty?

        host == pattern || host.end_with?(".#{pattern}")
      end
    end
  end
end
