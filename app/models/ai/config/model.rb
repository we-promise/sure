# A model on an endpoint, with what it can do, and its budgets:
# - batch_size: at most this many items in one call;
# - context_window: the tokens one request may use, nil when unknown (no token slicing);
# - max_output_tokens: sent as the request's limit; nil sends none.
class Ai::Config::Model < Data.define(:endpoint, :name, :capabilities, :context_window, :max_output_tokens,
                                      :batch_size, :embedding_dimensions)
  CAPABILITIES = %w[tools vision documents ocr thinking streaming structured_output embedding judge calibrated_confidence].freeze
  DEFAULT_BATCH_SIZE = 25   # LLM_MAX_ITEMS_PER_CALL's default

  def initialize(endpoint:, name:, capabilities: [], context_window: nil, max_output_tokens: nil,
                 batch_size: DEFAULT_BATCH_SIZE, embedding_dimensions: nil)
    capabilities = Array(capabilities).map(&:to_s).uniq.freeze
    unknown = capabilities - CAPABILITIES
    raise ArgumentError, "unknown capabilities: #{unknown.join(", ")}" if unknown.any?

    super
  end

  def capable?(*needed) = needed.flatten.all? { capabilities.include?(_1.to_s) }

  def inspect = "#<Ai::Config::Model #{endpoint&.name}/#{name}>"
  alias_method :to_s, :inspect

  # What instrumentation records as the route: endpoint and model, never the key.
  def to_event = { endpoint: endpoint.name, model: name }
end
