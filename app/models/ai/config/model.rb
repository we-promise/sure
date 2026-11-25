# A model on an endpoint, with what it can do.
class Ai::Config::Model < Data.define(:endpoint, :name, :capabilities, :embedding_dimensions)
  CAPABILITIES = %w[tools vision documents ocr thinking streaming structured_output embedding judge calibrated_confidence].freeze

  def initialize(endpoint:, name:, capabilities: [], embedding_dimensions: nil)
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
