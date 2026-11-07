# A model on an endpoint, with what it can do, and its budgets:
# - batch_size: at most this many items in one call;
# - context_window: the tokens one request may use, nil when unknown (no token slicing);
# - max_output_tokens: sent as the request's limit; nil sends none.
class Ai::Config::Model < Data.define(:endpoint, :name, :capabilities, :context_window, :max_output_tokens,
                                      :batch_size, :embedding_dimensions, :input_cost_per_mtok, :output_cost_per_mtok)
  CAPABILITIES = %w[tools vision documents ocr thinking streaming structured_output embedding judge calibrated_confidence].freeze
  DEFAULT_BATCH_SIZE = 25   # today's LLM_MAX_ITEMS_PER_CALL default

  def initialize(endpoint:, name:, capabilities: [], context_window: nil, max_output_tokens: nil,
                 batch_size: DEFAULT_BATCH_SIZE, embedding_dimensions: nil, input_cost_per_mtok: nil, output_cost_per_mtok: nil)
    capabilities = Array(capabilities).map(&:to_s).uniq.freeze
    unknown = capabilities - CAPABILITIES
    raise ArgumentError, "unknown capabilities: #{unknown.join(", ")}" if unknown.any?

    super
  end

  def capable?(*needed) = needed.flatten.all? { capabilities.include?(_1.to_s) }

  # The cost from this model's own prices, or nil when it has none (local models, and any
  # model configured without prices).
  def cost_for(tokens)
    return if input_cost_per_mtok.nil? || output_cost_per_mtok.nil? || !tokens&.known?

    (tokens.prompt_tokens.to_i * input_cost_per_mtok + tokens.output_tokens.to_i * output_cost_per_mtok) / 1_000_000.0
  end

  def inspect = "#<Ai::Config::Model #{endpoint&.name}/#{name}>"
  alias_method :to_s, :inspect

  # What instrumentation records as the route: endpoint and model, never the key.
  def to_event = { endpoint: endpoint.name, model: name }
end
