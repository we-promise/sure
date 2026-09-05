# The browser origins allowed to make cross-origin requests to this instance.
#
# Configured with ALLOWED_ORIGINS (comma-separated, full origins including the
# scheme), falling back to APP_DOMAIN for the common single-host deploy.
#
# When neither is set the list is empty, which means no Access-Control-Allow-Origin
# header is sent and browsers apply their same-origin default. That is the safe
# outcome, and the boot warning tells the operator how to widen it.
module CorsOrigins
  module_function

  def list
    explicit_origins.presence || app_domain_origin
  end

  def explicit_origins
    ENV["ALLOWED_ORIGINS"].to_s.split(",").filter_map { |origin| normalize(origin) }
  end

  def app_domain_origin
    domain = ENV["APP_DOMAIN"].to_s.strip
    return [] if domain.empty?

    # APP_DOMAIN is documented as a bare domain, but the WebAuthn initializer
    # already copes with operators pasting a full URL, so do the same here
    # rather than building "https://https://app.example.com".
    origin = domain.match?(%r{\Ahttps?://}i) ? domain : "#{scheme}://#{domain}"
    [ normalize(origin) ].compact
  end

  def scheme
    config = Rails.application.config
    ssl = config.force_ssl || (config.respond_to?(:assume_ssl) && config.assume_ssl)
    ssl ? "https" : "http"
  end

  # An Origin header carries a lowercased scheme and host, no path and no
  # trailing slash. Operators write the value by hand, often copied from a
  # browser's address bar, so normalize what they give us instead of failing
  # the comparison silently.
  def normalize(origin)
    value = origin.to_s.strip
    return nil if value.empty?

    uri = begin
      URI.parse(value)
    rescue URI::InvalidURIError
      nil
    end
    return nil if uri.nil? || uri.scheme.nil? || uri.host.nil?

    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}"
  end
end
