# One connection a transport talks to (section 4.2): protocol, URL, key and tuning. Transports
# take these values and never read ENV, Setting or ActiveRecord themselves. In 2a, AiHealth's
# probes build them from today's settings; 2b's Ai::Config holds them for every feature, and
# PR 7 copies `ai_endpoints` rows into them.
class Ai::Config::Endpoint < Data.define(:name, :protocol, :preset, :base_url, :api_key, :extra_headers, :location,
                                         :timeout_seconds, :max_retries, :responses_api, :probe_check)
  PROTOCOLS = %i[compatible anthropic jev].freeze
  LOCATIONS = %i[local cloud].freeze
  # What a health probe checks (decision 4 in pr-2a-transports-and-instrumentation.md):
  # :models lists the server's models and makes no chat call; :chat sends a tiny chat request,
  # which also catches a spent balance and a server that answers for a model it hasn't loaded.
  # The admin who configures the endpoint chooses, from PR 7; until then it's always :models.
  PROBE_CHECKS = %i[models chat].freeze

  def initialize(name:, protocol:, preset: nil, base_url: nil, api_key: nil, extra_headers: {}, location: :cloud,
                 timeout_seconds: 60, max_retries: 0, responses_api: false, probe_check: :models)
    protocol = protocol.to_sym
    location = location.to_sym
    probe_check = probe_check.to_sym
    raise ArgumentError, "unknown protocol #{protocol.inspect}" unless PROTOCOLS.include?(protocol)
    raise ArgumentError, "unknown location #{location.inspect}" unless LOCATIONS.include?(location)
    raise ArgumentError, "unknown probe check #{probe_check.inspect}" unless PROBE_CHECKS.include?(probe_check)

    super(name: name.to_s, protocol:, preset: preset&.to_sym, base_url: base_url.presence, api_key: api_key.presence,
          extra_headers: extra_headers.to_h.transform_keys(&:to_s).freeze, location:, timeout_seconds: Integer(timeout_seconds),
          max_retries: Integer(max_retries), responses_api: responses_api ? true : false, probe_check:)
  end

  def local? = location == :local
  def cloud? = location == :cloud

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
