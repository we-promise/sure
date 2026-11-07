# Deprecated: today's Jev settings (`JEV_*`, then the `jev_*` Setting fields), read for
# Ai::LegacyEnvConfig and the hostings page until PR 7 moves them into `ai_endpoints`. Moved here
# from Provider::Jev, whose wire code the `jev` transport replaced (2d).
#
# RubyLLM 2.1.1's `judge` posts to `<base>/v1/systemone` (section 7), so an endpoint must end in
# that path. OpenRouter's decisions gateway needs RubyLLM 2.2 (#1264, PR 5), and any other path
# can't be reached; both are left out of the config with a warning, and the form refuses them.
module Ai::LegacyEnvConfig::Jev
  DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone".freeze
  DEFAULT_MODEL = "jev-latest".freeze

  # TypeSafe's own API. Anything else is a gateway or a self-hosted server, which the data-sharing
  # notice names instead of claiming TypeSafe receives the data.
  VENDOR_HOST = "api.typesafe.ai".freeze

  module_function

  # Deliberately not OPENROUTER_API_KEY: a key set for another purpose mustn't turn Jev on.
  def api_key = ENV["JEV_API_KEY"].presence || Setting.jev_api_key.presence

  def configured? = api_key.present?

  def effective_model = (ENV["JEV_MODEL"].presence || Setting.jev_model).presence || DEFAULT_MODEL

  def effective_endpoint = (ENV["JEV_ENDPOINT"].presence || Setting.jev_endpoint).presence || DEFAULT_ENDPOINT

  # https anywhere; http is a server on a private network, the operator's call (section 7). Named
  # explicitly, because URI::HTTPS subclasses URI::HTTP.
  def endpoint_allowed?(url)
    uri = URI.parse(url.to_s)
    %w[http https].include?(uri.scheme) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  # Why RubyLLM can't reach the endpoint, or nil: :openrouter until PR 5, :path for any other.
  def unsupported_reason(url)
    uri = URI.parse(url.to_s)
    return :openrouter if uri.host.to_s.end_with?("openrouter.ai") || uri.path.to_s.end_with?("/alpha/decisions")
    return :path unless uri.path.to_s.chomp("/").end_with?(Ai::Transport::Jev::PATH) && uri.query.blank?

    nil
  rescue URI::InvalidURIError
    :path
  end

  # Why the endpoint can't be used, or nil: :path for a URL that isn't http(s) with a host, else
  # unsupported_reason. The config, the categorizer's fallback log and the eval runner all ask this.
  def unreachable_reason(url) = endpoint_allowed?(url) ? unsupported_reason(url) : :path

  # The base RubyLLM appends `/v1/systemone` to.
  def base_url(url)
    uri = URI.parse(url.to_s)
    uri.path = uri.path.chomp("/").delete_suffix(Ai::Transport::Jev::PATH)
    uri.to_s
  end

  def host_for(endpoint)
    URI.parse(endpoint.to_s).host.presence || endpoint.to_s
  rescue URI::InvalidURIError
    endpoint.to_s
  end

  def effective_host = host_for(effective_endpoint)

  def effective_proxied? = effective_host != VENDOR_HOST

  # The endpoint without its credential-bearing parts, for logs, messages and the settings field.
  # A gateway URL can carry a key in userinfo or the query, and DebugLogEntry rows are exported
  # for support. The password is cleared before the user, or the assignment raises.
  def redacted_endpoint(url)
    uri = URI.parse(url.to_s)
    uri.password = nil if uri.respond_to?(:password) && uri.password
    uri.user = nil if uri.respond_to?(:user) && uri.user
    uri.query = nil
    uri.fragment = nil
    uri.to_s
  rescue URI::Error, NoMethodError
    "[unparseable endpoint]"
  end
end
