# One connection a transport talks to: protocol, URL, key and tuning. Transports take these
# values and never read ENV, Setting or ActiveRecord themselves. Ai::Config holds them, built by
# Ai::LegacyEnvConfig from the current settings.
#
# - vector_store: the endpoint offers OpenAI-style vector stores, which the `embed` route uses.
# - agent: the endpoint is an external assistant, which serves only `chat`, for families whose
#   chat mode is external. agent_settings holds its allowed emails, agent id and session key.
class Ai::Config::Endpoint < Data.define(:name, :protocol, :preset, :base_url, :api_key, :extra_headers, :location,
                                         :timeout_seconds, :max_retries, :responses_api, :probe_check, :vector_store,
                                         :agent, :agent_settings)
  PROTOCOLS = %i[compatible anthropic jev].freeze
  LOCATIONS = %i[local cloud].freeze
  # What a health probe checks:
  # :models lists the server's models and makes no chat call; :chat sends a tiny chat request,
  # which also catches a spent balance and a server that answers for a model it hasn't loaded.
  # :models is the default, so a probe makes no chat call unless its endpoint asks for one.
  PROBE_CHECKS = %i[models chat].freeze

  def initialize(name:, protocol:, preset: nil, base_url: nil, api_key: nil, extra_headers: {}, location: :cloud,
                 timeout_seconds: 60, max_retries: 0, responses_api: false, probe_check: :models, vector_store: false,
                 agent: false, agent_settings: {})
    protocol = protocol.to_sym
    location = location.to_sym
    probe_check = probe_check.to_sym
    raise ArgumentError, "unknown protocol #{protocol.inspect}" unless PROTOCOLS.include?(protocol)
    raise ArgumentError, "unknown location #{location.inspect}" unless LOCATIONS.include?(location)
    raise ArgumentError, "unknown probe check #{probe_check.inspect}" unless PROBE_CHECKS.include?(probe_check)

    super(name: name.to_s, protocol:, preset: preset&.to_sym, base_url: base_url.presence, api_key: api_key.presence,
          extra_headers: extra_headers.to_h.transform_keys(&:to_s).freeze, location:, timeout_seconds: Integer(timeout_seconds),
          max_retries: Integer(max_retries), responses_api: responses_api ? true : false, probe_check:,
          vector_store: vector_store ? true : false, agent: agent ? true : false,
          agent_settings: agent_settings.to_h.transform_keys(&:to_sym).freeze)
  end

  def local? = location == :local
  def cloud? = location == :cloud
  def agent? = agent
  def vector_store? = vector_store

  # What scrubbing removes from any text about this endpoint: the key, and every static header
  # value long enough to be a credential, since a gateway can take one in a header.
  def secrets = [ api_key, *extra_headers.values.map(&:to_s).select { _1.length >= 8 } ].compact_blank

  # Never shows the key or header values, which can carry credentials.
  def inspect
    "#<Ai::Config::Endpoint #{name} #{protocol} #{location} #{Ai::Instrumentation::Redactor.url(base_url).inspect}>"
  end
  alias_method :to_s, :inspect

  # What instrumentation may record about the endpoint.
  def to_event = { name:, protocol:, preset:, location: }.compact
end
