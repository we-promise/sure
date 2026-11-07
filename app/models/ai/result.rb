# What every AI call returns. `call` returns one; `call!` returns its value or
# raises its Ai::Error.
Ai::Result = Data.define(:value, :error, :availability, :usage, :route, :failed_over_from, :remaining, :correlation_id) do
  def initialize(value: nil, error: nil, availability: nil, usage: nil, route: nil, failed_over_from: nil, remaining: [], correlation_id: nil)
    super
  end

  def self.unavailable(availability) = new(availability:)

  def self.failure(error, **attributes) = new(error:, **attributes)

  def success?     = error.nil? && availability.nil?
  def unavailable? = !availability.nil?
  def cancelled?   = error.is_a?(Ai::Error::Cancelled)

  # Items a batched call didn't reach.
  def remaining_ids = remaining.map(&:id)

  def value!
    raise error if error
    raise Ai::Error::Unavailable, availability.respond_to?(:reason) ? availability.reason : availability if unavailable?

    value
  end
end
