# Shadow runs: after a successful call, the same feature on its `shadow_<feature>` route, as its
# own job in the background lane, compared and never applied. Any batched generation can declare
# `shadow`, with a requester that rebuilds it from ids (`ai_shadow_generation`); `categorize` is
# the only one that does.
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

  # Samples the call and, on a hit, enqueues Ai::ShadowJob with the fingerprint of the items the
  # primary was sent and its compared answer, never the items themselves: job arguments sit in Redis
  # and the Sidekiq UI, and the items hold the family's data. The items include those the primary
  # couldn't answer, so the shadow can show where it does better; those in `result.remaining` go to
  # a later job, whose own shadow covers them. Never raises: a diagnostic mustn't break the call it
  # observes.
  def enqueue(generation, result)
    feature = generation.feature_key
    return unless generation.shadow_compare && generation.items && result.success? && result.route
    return unless Ai::Routes::MATRIX.key?(feature_for(feature))

    rate = rate(feature, generation.family)
    return unless rate.positive? && rand < rate
    return unless Ai::Router.new(family: generation.family).resolve(feature_for(feature)).is_a?(Ai::Plan)

    # Identity, not value: the same transaction can appear twice in a batch. Build the lookup
    # once, so filtering is linear even when the generation still holds a large workload.
    remaining = {}.compare_by_identity
    result.remaining.each { |item| remaining[item] = true }
    sent = generation.items.reject { remaining.key?(_1) }
    Ai::ShadowJob.perform_later(feature.to_s, generation.family.id, fingerprint(generation, sent), side(generation, result))
  rescue StandardError => error
    Rails.logger.warn("[Ai::Shadow] #{feature} for family #{generation.family&.id} not enqueued: #{error.class}: #{error.message}")
    nil
  end

  # What the shadow job checks the rebuilt input against, so an item edited while the job waits
  # isn't compared with an answer about its old text: a digest of each item by id, and one of
  # everything else the generation was given (categorize's categories). Digests only, no family text.
  def fingerprint(generation, items = generation.items)
    { items: items.to_h { [ _1[:id].to_s, digest(_1) ] }, context: digest(generation.arguments.except(generation.batch_key)) }
  end

  def digest(value) = Digest::SHA256.hexdigest(value.to_json).first(16)

  # A side's values and routes for `ids` only.
  def only(side, ids)
    side.merge(values: side[:values].to_h.select { |id, _| ids.include?(id.to_s) },
               routes: side[:routes].to_h.select { |id, _| ids.include?(id.to_s) })
  end

  # One side of a comparison: each item's compared value, the route that answered it (a slice can
  # be answered part by a route and part by its fallback), and the call's last route for items
  # this side didn't answer.
  def side(generation, result)
    values = generation.compared(result.value)
    answered_by = result.answered_by.transform_keys(&:to_s)
    routes = values.keys.to_h { [ _1, (answered_by[_1] || result.route)&.to_event ] }
    { route: result.route&.to_event, values:, routes: routes.compact }
  end
end
