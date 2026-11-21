# Every AI HTTP client is built here: the endpoint's timeout and headers, TLS
# settings, and the proxy, resolved once. A contract test checks that nothing under
# app/models/ai/ builds a client anywhere else.
#
# The proxy comes from ProxyConfigurable, Sure's one resolver. It covers RubyLLM's contexts,
# the ruby-openai clients built below (health probes, Provider::Openai) and
# Assistant::External::Client. The anthropic gem takes no proxy option (Net::HTTP reads only
# HTTP_PROXY, even for HTTPS), so Anthropic's own client goes direct.
module Ai::Transport::Http
  extend SslConfigurable

  OPENAI_BASE = "https://api.openai.com/v1".freeze
  OPENROUTER_BASE = "https://openrouter.ai/api/v1".freeze

  class << self
    # The proxy URL for a request to `url`, or nil to go direct, from ProxyConfigurable.
    def proxy_for(url, env: ENV) = ProxyConfigurable.url_for(url, env:)

    # One base URL rule for every OpenAI-compatible server, the same as ruby-openai's, so an
    # endpoint configured for ruby-openai keeps its URL: a URL that contains "v1" is used as given
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
    # Its base follows compatible_base, as RubyLLM's does, so the models list and the chat calls
    # it checks reach the same server; an OpenRouter endpoint without a URL is OpenRouter's.
    def openai_client(endpoint, timeout: endpoint.timeout_seconds)
      base = endpoint.base_url.presence || (OPENROUTER_BASE if endpoint.preset == :openrouter)
      options = { access_token: endpoint.api_key.to_s, request_timeout: timeout }
      options[:uri_base] = compatible_base(base) if base
      static = headers(endpoint)
      options[:extra_headers] = static if static.any?

      ::OpenAI::Client.new(**options, &faraday_options(base || OPENAI_BASE))
    end

    # The anthropic gem's client, for the Anthropic PDF probe, as PDF import uses it. It takes no
    # proxy or TLS options, so it ignores HTTPS_PROXY and SSL_VERIFY=false, as PDF import does
    # until it moves onto RubyLLM.
    def anthropic_client(endpoint, timeout: endpoint.timeout_seconds)
      options = { api_key: endpoint.api_key.to_s, max_retries: 0, timeout: }
      options[:base_url] = endpoint.base_url if endpoint.base_url.present?
      ::Anthropic::Client.new(**options)
    end

    # A plain Faraday connection for a request no client library makes (Anthropic's model lookup),
    # with the resolved proxy and TLS options.
    def faraday(url, timeout:)
      Faraday.new(request: { timeout:, open_timeout: timeout }, &faraday_options(url))
    end

    # The Faraday adapter for RubyLLM's contexts, which take no TLS options of their own.
    def ruby_llm_adapter = TlsNetHttp

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
  end

  # Net::HTTP with Sure's TLS settings (SSL_VERIFY, SSL_CA_FILE) and Sure's proxy decision on
  # every request. RubyLLM 2.1.1 builds its own Faraday connections and takes only an adapter,
  # so this is how a self-hosted server with its own certificate is reached by RubyLLM as by every
  # other client. RubyLLM sets a proxy only when given one; without this, a request
  # Ai::Transport::Http.proxy_for sends direct would fall back to Faraday's own ENV lookup, which
  # ignores the port in a NO_PROXY entry such as `10.0.0.5:8080`.
  class TlsNetHttp < Faraday::Adapter::NetHttp
    def build_connection(env)
      ssl = Ai::Transport::Http.faraday_ssl_options
      env[:ssl] = env[:ssl] ? env[:ssl].merge(ssl) : Faraday::SSLOptions.from(ssl) if ssl.present?
      proxy = Ai::Transport::Http.proxy_for(env[:url].to_s)
      env[:request][:proxy] = proxy && Faraday::ProxyOptions.from(proxy)
      super
    end
  end
end
