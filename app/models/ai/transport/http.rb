# Every AI HTTP client is built here (section 7): the endpoint's timeout and headers, TLS
# settings, and the proxy, resolved once. A contract test checks that nothing under
# app/models/ai/ builds a client anywhere else.
#
# Proxy coverage in PR 2a: RubyLLM's contexts, the ruby-openai clients built below (health
# probes, Provider::Openai) and Assistant::External::Client. The anthropic gem takes no proxy
# option (Net::HTTP reads only HTTP_PROXY, even for HTTPS), so Anthropic's own client goes
# direct until its calls move onto RubyLLM (2c, PR 6).
module Ai::Transport::Http
  extend SslConfigurable

  OPENAI_BASE = "https://api.openai.com/v1".freeze
  PROXY_VARIABLES = %w[HTTPS_PROXY https_proxy HTTP_PROXY http_proxy].freeze

  class << self
    # The proxy URL for a request to `url`, or nil to go direct: HTTPS_PROXY, then HTTP_PROXY,
    # whatever the target's scheme, so a setup that sets only one still covers every call.
    # Loopback is never proxied, as Ruby's own lookup does; NO_PROXY matches a host exactly as
    # written, so `127.0.0.1` doesn't cover `localhost`.
    def proxy_for(url, env: ENV)
      uri = parse(url)
      return if uri&.host.blank? || loopback?(uri.host)

      proxy = PROXY_VARIABLES.lazy.filter_map { env[_1].presence }.first
      return if proxy.nil?

      no_proxy = env["NO_PROXY"].presence || env["no_proxy"].presence
      return if no_proxy && !URI::Generic.use_proxy?(uri.host, uri.host, uri.port, no_proxy)

      proxy
    end

    # The proxy for Net::HTTP.new, which takes host, port, user and password.
    def net_http_proxy(url, env: ENV)
      proxy = proxy_for(url, env:)
      URI(proxy) if proxy
    rescue URI::InvalidURIError
      Rails.logger.warn("[Ai::Transport::Http] Invalid proxy URL ignored")
      nil
    end

    # One base URL rule for every OpenAI-compatible server, the same as ruby-openai's, so an
    # endpoint configured today keeps its URL: a URL that contains "v1" is used as given
    # (`/v1`, Gemini's `/v1beta/openai`, Cloudflare's `/ai/v1`); any other gets `/v1`. Agent
    # URLs are stored whole, so a trailing `/chat/completions` goes.
    def compatible_base(base_url)
      url = base_url.to_s.strip.chomp("/").delete_suffix("/chat/completions")
      return OPENAI_BASE if url.blank?

      url.include?("v1") ? url : "#{url}/v1"
    end

    # Headers sent on every request. Values holding `{session_id}` are filled per chat request
    # by Provider::Openai, so they're left out here.
    def headers(endpoint) = endpoint.extra_headers.reject { |_, value| value.to_s.include?("{session_id}") }

    # The ruby-openai client for an endpoint: vector stores, the PDF probes and model listing
    # stay on ruby-openai (RubyLLM has no vector store calls).
    def openai_client(endpoint, timeout: endpoint.timeout_seconds)
      options = { access_token: endpoint.api_key.to_s, request_timeout: timeout }
      options[:uri_base] = endpoint.base_url if endpoint.base_url.present?
      static = headers(endpoint)
      options[:extra_headers] = static if static.any?

      ::OpenAI::Client.new(**options, &faraday_options(endpoint.base_url.presence || OPENAI_BASE))
    end

    # The anthropic gem's client: model listing and the Anthropic PDF probe. It takes no proxy.
    def anthropic_client(endpoint, timeout: endpoint.timeout_seconds)
      options = { api_key: endpoint.api_key.to_s, max_retries: 0, timeout: }
      options[:base_url] = endpoint.base_url if endpoint.base_url.present?
      ::Anthropic::Client.new(**options)
    end

    # A Faraday block for a client built elsewhere (ruby-openai): the resolved proxy, which
    # also stops Faraday's own ENV lookup when the resolver says direct, and TLS options.
    def faraday_options(url)
      proxy = proxy_for(url)
      ssl = faraday_ssl_options

      lambda do |faraday|
        faraday.proxy = proxy
        faraday.ssl.update(ssl) if ssl.present?
      end
    end

    private
      def parse(url)
        URI(url.to_s)
      rescue URI::InvalidURIError
        nil
      end

      def loopback?(host)
        host = host.delete_prefix("[").delete_suffix("]")
        host.casecmp?("localhost") || IPAddr.new(host).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end
  end
end
