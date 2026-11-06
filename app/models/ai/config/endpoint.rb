# One connection a transport talks to (section 4.2): protocol, URL, key and tuning. Transports
# take these values and never read ENV, Setting or ActiveRecord themselves. Ai::Config holds
# them (built by Ai::LegacyEnvConfig until PR 7 copies `ai_endpoints` rows into them).
#
# - vector_store: the endpoint offers OpenAI-style vector stores, which the `embed` route uses
#   (section 5.5).
# - agent: the endpoint is an external assistant, which serves only `chat`, for families whose
#   chat mode is external (section 5.6). agent_settings holds its allowed emails, agent id and
#   session key.
# - json_mode: how chat completions ask for JSON (section 7). A route entry can override it.
#   The Responses API and Anthropic always send the schema.
# - parallel_requests: how many requests one call may have in flight. Only the Jev transport
#   fans out (section 7); nil uses its preset's default.
class Ai::Config::Endpoint < Data.define(:name, :protocol, :preset, :base_url, :api_key, :extra_headers, :location,
                                         :timeout_seconds, :max_retries, :responses_api, :probe_check, :vector_store,
                                         :agent, :agent_settings, :json_mode, :parallel_requests)
  PROTOCOLS = %i[compatible anthropic jev].freeze
  LOCATIONS = %i[local cloud].freeze
  # What a health probe checks (decision 4 in pr-2a-transports-and-instrumentation.md):
  # :models lists the server's models and makes no chat call; :chat sends a tiny chat request,
  # which also catches a spent balance and a server that answers for a model it hasn't loaded.
  # The admin who configures the endpoint chooses, from PR 7; until then it's always :models.
  PROBE_CHECKS = %i[models chat].freeze
  JSON_MODES = %i[auto strict json_object none].freeze

  def initialize(name:, protocol:, preset: nil, base_url: nil, api_key: nil, extra_headers: {}, location: :cloud,
                 timeout_seconds: 60, max_retries: 0, responses_api: false, probe_check: :models, vector_store: false,
                 agent: false, agent_settings: {}, json_mode: :auto, parallel_requests: nil)
    protocol = protocol.to_sym
    location = location.to_sym
    probe_check = probe_check.to_sym
    json_mode = json_mode.to_sym
    raise ArgumentError, "unknown protocol #{protocol.inspect}" unless PROTOCOLS.include?(protocol)
    raise ArgumentError, "unknown location #{location.inspect}" unless LOCATIONS.include?(location)
    raise ArgumentError, "unknown probe check #{probe_check.inspect}" unless PROBE_CHECKS.include?(probe_check)
    raise ArgumentError, "unknown JSON mode #{json_mode.inspect}" unless JSON_MODES.include?(json_mode)

    super(name: name.to_s, protocol:, preset: preset&.to_sym, base_url: base_url.presence, api_key: api_key.presence,
          extra_headers: extra_headers.to_h.transform_keys(&:to_s).freeze, location:, timeout_seconds: Integer(timeout_seconds),
          max_retries: Integer(max_retries), responses_api: responses_api ? true : false, probe_check:,
          vector_store: vector_store ? true : false, agent: agent ? true : false,
          agent_settings: agent_settings.to_h.transform_keys(&:to_sym).freeze, json_mode:,
          parallel_requests: parallel_requests && Integer(parallel_requests))
  end

  # What a provider takes inline as a PDF, by preset (section 8.1), until PR 7's preset files
  # record it. A bigger file is read through its text layer or page images instead.
  PDF_LIMITS = {
    anthropic: { bytes: 32.megabytes, pages: 100 },
    openai: { bytes: 32.megabytes, pages: 100 }
  }.freeze

  def pdf_limits = PDF_LIMITS[preset]

  def local? = location == :local
  def cloud? = location == :cloud
  def agent? = agent
  def vector_store? = vector_store

  # Never shows the key or header values, which can carry credentials.
  def inspect
    "#<Ai::Config::Endpoint #{name} #{protocol} #{location} #{Ai::Instrumentation::Redactor.url(base_url).inspect}>"
  end
  alias_method :to_s, :inspect

  # What instrumentation may record about the endpoint.
  def to_event = { name:, protocol:, preset:, location: }.compact
end
