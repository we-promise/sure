# Writes Ai::Comparison rows from a shadow run's `compare.ai_shadow` event: one row
# per item either side answered. An item both answered agrees when the values match, a shared
# abstention included; an item only one side answered never agrees, or a missing answer would
# count as agreement.
#
# The only reader of shadow results (test/architecture/ai_shadow_test). A failure is logged and
# swallowed: a diagnostic mustn't break the job that observes.
class Ai::Instrumentation::ComparisonSubscriber
  def call(event)
    payload = event.payload
    primary, shadow = payload.dig(:primary, :values).to_h, payload.dig(:shadow, :values).to_h
    primary, shadow = primary.transform_keys(&:to_s), shadow.transform_keys(&:to_s)
    now = Time.current

    rows = (primary.keys | shadow.keys).map do |id|
      primary_value, primary_confidence = primary[id]
      shadow_value, shadow_confidence = shadow[id]
      {
        feature: payload[:feature].to_s, family_id: payload[:family_id],
        subject_type: payload[:subject_type], subject_id: id,
        primary_route: payload.dig(:primary, :route), shadow_route: payload.dig(:shadow, :route),
        primary_value:, shadow_value:, primary_confidence:, shadow_confidence:,
        agreed: primary.key?(id) && shadow.key?(id) && primary_value == shadow_value,
        metadata: {}, created_at: now, updated_at: now
      }
    end
    # The subject_id column is uuid; an id that isn't one can't be read back by item
    # later, so the row would be unreachable garbage. Say so and drop it, rather than
    # store a comparison no one can join to anything.
    uuid_rows, dropped = rows.partition { Ai::Comparison::UUID.match?(_1[:subject_id].to_s) }
    if dropped.any?
      Rails.logger.error("[Ai::Instrumentation::ComparisonSubscriber] dropped #{dropped.size} comparison(s) with non-uuid subject id (family_id=#{payload[:family_id]})")
    end
    Ai::Comparison.insert_all(uuid_rows) if uuid_rows.any?
  rescue StandardError => error
    family_id = defined?(payload) && payload.is_a?(Hash) ? payload[:family_id] : nil
    Rails.logger.error("[Ai::Instrumentation::ComparisonSubscriber] #{error.class}: #{error.message} (family_id=#{family_id})")
  end
end
