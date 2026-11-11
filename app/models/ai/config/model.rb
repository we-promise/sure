# A model on an endpoint, with what it can do, and its budgets:
# - batch_size: at most this many items in one call;
# - context_window: the tokens one request may use, nil when unknown (no token slicing);
# - max_output_tokens: sent as the request's limit; nil sends none;
# - ocr_prompt: for an `ocr` model read through chat, its prompt folder (app/prompts/ocr_<name>),
#   because OCR models differ in the prompt and chat template they expect. No UI or ENV sets
#   it yet.
class Ai::Config::Model < Data.define(:endpoint, :name, :capabilities, :context_window, :max_output_tokens,
                                      :batch_size, :embedding_dimensions, :input_cost_per_mtok, :output_cost_per_mtok,
                                      :ocr_prompt)
  CAPABILITIES = %w[tools vision documents ocr thinking streaming structured_output embedding judge calibrated_confidence].freeze
  DEFAULT_BATCH_SIZE = 25   # LLM_MAX_ITEMS_PER_CALL's default
  # OCR prompt folders (app/prompts/ocr_<name>): `markdown` asks a general vision model for a
  # Markdown transcription; `unlimited_ocr_2` is the model card's "<PAGE>" per page, then
  # "Multi page parsing.", for GGUF templates that don't write it themselves.
  OCR_PROMPTS = %w[markdown unlimited_ocr_2].freeze

  def initialize(endpoint:, name:, capabilities: [], context_window: nil, max_output_tokens: nil,
                 batch_size: DEFAULT_BATCH_SIZE, embedding_dimensions: nil, input_cost_per_mtok: nil, output_cost_per_mtok: nil,
                 ocr_prompt: nil)
    capabilities = Array(capabilities).map(&:to_s).uniq.freeze
    unknown = capabilities - CAPABILITIES
    raise ArgumentError, "unknown capabilities: #{unknown.join(", ")}" if unknown.any?
    ocr_prompt = ocr_prompt&.to_s
    raise ArgumentError, "unknown OCR prompt #{ocr_prompt.inspect}" if ocr_prompt && !OCR_PROMPTS.include?(ocr_prompt)

    super
  end

  def capable?(*needed) = needed.flatten.all? { capabilities.include?(_1.to_s) }

  def inspect = "#<Ai::Config::Model #{endpoint&.name}/#{name}>"
  alias_method :to_s, :inspect

  # What instrumentation records as the route: endpoint and model, never the key.
  def to_event = { endpoint: endpoint.name, model: name }
end
