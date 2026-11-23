# Writes Ai::Comparison rows from a shadow run's `compare.ai_shadow` event: one row
# per item either side answered, each with the route that answered it on each side. An item both answered agrees when the values match, a shared
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
    primary_routes, shadow_routes = routes(payload[:primary]), routes(payload[:shadow])
    now = Time.current

    rows = (primary.keys | shadow.keys).map do |id|
      primary_value, primary_confidence = primary[id]
      shadow_value, shadow_confidence = shadow[id]
      {
        feature: payload[:feature].to_s, family_id: payload[:family_id],
        subject_type: payload[:subject_type], subject_id: id,
        primary_route: primary_routes[id], shadow_route: shadow_routes[id],
        primary_value:, shadow_value:, primary_confidence:, shadow_confidence:,
        agreed: primary.key?(id) && shadow.key?(id) && primary_value == shadow_value,
        metadata: {}, created_at: now, updated_at: now
      }
    end
    # subject_id is a uuid column, so a row whose item id isn't one is logged and dropped.
    uuid_rows, dropped = rows.partition { UuidFormat.valid?(_1[:subject_id]) }
    if dropped.any?
      Rails.logger.error("[Ai::Instrumentation::ComparisonSubscriber] dropped #{dropped.size} comparison(s) with non-uuid subject id (family_id=#{payload[:family_id]})")
    end
    Ai::Comparison.insert_all(uuid_rows) if uuid_rows.any?
  rescue StandardError => error
    Rails.logger.error("[Ai::Instrumentation::ComparisonSubscriber] #{error.class}: #{error.message} (family_id=#{payload.try(:[], :family_id)})")
  end

  private
    # Each item's route on one side, falling back to the call's last route for an item it didn't answer.
    def routes(side)
      by_item = side.to_h[:routes].to_h.transform_keys(&:to_s)
      Hash.new(side.to_h[:route] || {}).merge(by_item)
    end
end
