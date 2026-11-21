# What every AI call returns. `call` returns one; `call!` returns its value or
# raises its Ai::Error.
# `route` is the last route that answered; `answered_by` maps each answered item id to its own,
# since a slice can be answered part by one route and part by its fallback.
# `skipped` holds the items no route could answer, which the call logged and went on without.
Ai::Result = Data.define(:value, :error, :availability, :route, :remaining, :answered_by, :skipped) do
  def initialize(value: nil, error: nil, availability: nil, route: nil, remaining: [], answered_by: {}, skipped: [])
    super
  end

  def route_for(item_id) = answered_by.fetch(item_id, route)

  def self.unavailable(availability) = new(availability:)

  def self.failure(error, **attributes) = new(error:, **attributes)

  def success?     = error.nil? && availability.nil?
  def unavailable? = !availability.nil?
  def cancelled?   = error.is_a?(Ai::Error::Cancelled)

  # Items a batched call didn't reach.
  def remaining_ids = remaining.map { _1.is_a?(Hash) ? _1[:id] : _1.id }

  def value!
    raise error if error
    raise Ai::Error::Unavailable, availability.reason if unavailable?

    value
  end
end
