# A shadow run: the primary's items, rebuilt from their ids by the feature's requester
# (`ai_shadow_generation`) and checked against the digests of what the primary was sent
# (Ai::Shadow.fingerprint), run on the `shadow_<feature>` route. An item edited since is left out
# of both sides; a changed context (categorize's categories) skips the run. Its calls are recorded under
# shadow_<feature>, so usage shows shadow spend apart, and its answer goes only to the
# `compare.ai_shadow` event, which Ai::Instrumentation::ComparisonSubscriber writes to
# Ai::Comparison. Nothing is applied.
#
# Never retried: a diagnostic that failed is skipped, and a deadlock is discarded rather than
# retried by ApplicationJob's retry_on.
class Ai::ShadowJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(Ai::Shadow.feature_for(arguments.first)) }
  sidekiq_options retry: false
  discard_on ActiveRecord::Deadlocked

  # feature: a key in Ai::Requesters whose requester defines ai_shadow_generation; sent:
  # Ai::Shadow.fingerprint of the items the primary was sent; primary: Ai::Shadow.side of the call
  # that was applied.
  def perform(feature, family_id, sent, primary)
    requester = Ai::Requesters.fetch(feature)
    raise ArgumentError, "#{feature} has no shadow" unless requester.method_defined?(:ai_shadow_generation)

    family = Family.find_by(id: family_id)
    return unless family

    shadow_feature = Ai::Shadow.feature_for(feature)
    Ai::CallContext.job("family:#{family.id}:#{shadow_feature}:#{SecureRandom.hex(8)}") do
      plan = Ai::Router.new(family:).resolve(shadow_feature)
      next unless plan.is_a?(Ai::Plan)

      sent = sent.to_h.with_indifferent_access
      generation = requester.from_shadow_job(ids: sent[:items].keys, family_id: family.id).ai_shadow_generation
      next if generation.nil?

      now = Ai::Shadow.fingerprint(generation)
      next log_failure(shadow_feature, family, "its context changed since the primary ran") if now[:context] != sent[:context]

      unchanged = generation.items.select { sent[:items][_1[:id].to_s] == now[:items][_1[:id].to_s] }
      next if unchanged.empty?

      generation = generation.with_items(unchanged)
      primary = Ai::Shadow.only(primary.deep_symbolize_keys, unchanged.map { _1[:id].to_s })

      result = generation.call(plan:)
      next log_failure(shadow_feature, family, result.error) unless result.success?

      ActiveSupport::Notifications.instrument(
        Ai::Shadow::EVENT,
        feature: generation.feature_key, family_id: family.id, subject_type: generation.shadow_subject,
        primary:, shadow: Ai::Shadow.side(generation, result)
      )
    end
  end

  private
    def log_failure(feature, family, reason)
      reason = "#{reason.class}: #{reason.message.to_s.truncate(200)}" if reason.is_a?(Exception)
      Rails.logger.warn("[Ai::ShadowJob] #{feature} for family #{family.id} skipped: #{reason}")
    end
end
