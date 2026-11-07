# A shadow run (section 8.2): the primary's generation, rebuilt from the input it was sent, run on
# the `shadow_<feature>` route. Its calls are recorded under shadow_<feature>, so usage shows
# shadow spend apart, and its answer goes only to the `compare.ai_shadow` event, which
# Ai::Instrumentation::ComparisonSubscriber writes to Ai::Comparison. Nothing is applied.
#
# Never retried: a diagnostic that failed is skipped, as the inline shadow run was.
class Ai::ShadowJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(Ai::Shadow.feature_for(arguments.first.constantize.feature_key)) }

  # generation_class: an Ai::Generation that declares `shadow`; arguments: its own, without the
  # family; primary: { route:, values: } from the call that was applied.
  def perform(generation_class, family_id, arguments, primary)
    klass = generation_class.constantize
    raise ArgumentError, "#{generation_class} declares no shadow" unless klass < Ai::Generation && klass.shadow_compare

    family = Family.find_by(id: family_id)
    return unless family

    feature = Ai::Shadow.feature_for(klass.feature_key)
    Ai::CallContext.job("family:#{family.id}:#{feature}") do
      plan = Ai::Router.new(family:).resolve(feature)
      next unless plan.is_a?(Ai::Plan)

      generation = klass.new(**arguments.to_h.symbolize_keys, family:)
      result = generation.call(plan:)
      next log_failure(feature, family, result.error) unless result.success?

      ActiveSupport::Notifications.instrument(
        Ai::Shadow::EVENT,
        feature: klass.feature_key, family_id: family.id, subject_type: klass.shadow_subject,
        primary: primary.deep_symbolize_keys, shadow: { route: result.route.to_event, values: generation.compared(result.value) }
      )
    end
  end

  private
    def log_failure(feature, family, error)
      Rails.logger.warn("[Ai::ShadowJob] #{feature} for family #{family.id} failed: #{error.class}: #{error.message.to_s.truncate(200)}")
    end
end
