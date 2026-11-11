# Shadow runs: after a successful call, the same feature on its `shadow_<feature>` route, as its
# own job in the background lane, compared and never applied. Any generation can declare
# `shadow`; `categorize` is the only one that does.
#
# The rate is the family's (`effective_categorization_shadow_rate`, with
# CATEGORIZATION_SHADOW_RATE over it), which is enough while categorize is the only feature with
# a shadow.
module Ai::Shadow
  EVENT = "compare.ai_shadow".freeze

  module_function

  def feature_for(feature) = :"shadow_#{feature}"

  def shadow?(feature) = Ai::Routes::MATRIX.dig(feature.to_sym, :shadow_of).present?

  def rate(feature, family)
    return 0.0 unless family

    feature.to_sym == :categorize ? family.effective_categorization_shadow_rate : 0.0
  end

  # Samples the call and, on a hit, enqueues Ai::ShadowJob with the items the primary was sent and
  # its answer: the job can't re-query, because that answer is already applied. The items include
  # those the primary couldn't answer, so the shadow can show where it does better; those in
  # `result.remaining` go to a later job, whose own shadow covers them. Never raises: a diagnostic
  # mustn't break the call it observes.
  def enqueue(generation, result)
    feature = generation.feature_key
    return unless result.success? && result.route && Ai::Routes::MATRIX.key?(feature_for(feature))

    rate = rate(feature, generation.family)
    return unless rate.positive? && rand < rate
    return unless Ai::Router.new(family: generation.family).resolve(feature_for(feature)).is_a?(Ai::Plan)

    sent = generation.items && generation.with_items(generation.items.reject { |item| result.remaining.any? { |r| r.equal?(item) } })
    arguments = (sent || generation).arguments
    primary = { route: result.route.to_event, values: generation.compared(result.value) }
    Ai::ShadowJob.perform_later(generation.class.name, generation.family.id, arguments, primary)
  rescue StandardError => error
    Rails.logger.warn("[Ai::Shadow] #{feature} for family #{generation.family&.id} not enqueued: #{error.class}: #{error.message}")
    nil
  end
end
