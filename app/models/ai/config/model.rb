# A model on an endpoint.
class Ai::Config::Model < Data.define(:endpoint, :name, :embedding_dimensions)
  def initialize(endpoint:, name:, embedding_dimensions: nil)
    super
  end

  def inspect = "#<Ai::Config::Model #{endpoint&.name}/#{name}>"
  alias_method :to_s, :inspect

  # What instrumentation records as the route: endpoint and model, never the key.
  def to_event = { endpoint: endpoint.name, model: name }
end
