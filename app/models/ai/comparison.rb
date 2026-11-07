# One item answered twice: by the route that was applied and by its shadow (section 8.2). Written
# only by Ai::Instrumentation::ComparisonSubscriber, never to the item itself. Values are ids (a
# category's, for categorize), and a confidence is null when a model gives none. Each route is
# stored with its endpoint, model and overrides, so a comparison reads "strict vs json_object"
# or "default prompt vs trial prompt", not the same route twice.
#
# Rows migrated from CategorizationComparison have the provider as the route's endpoint, and the
# category names they recorded in `metadata`.
class Ai::Comparison < ApplicationRecord
  self.table_name = "ai_comparisons"

  belongs_to :family
  belongs_to :subject, polymorphic: true, optional: true

  scope :for_feature, ->(feature) { where(feature: feature.to_s) }
  scope :disagreements, -> { where(agreed: false) }
  scope :chronological, -> { order(:created_at) }

  # Share of compared items where both routes gave the same answer, as a percentage; nil with
  # none. Both declining to answer counts as agreement.
  def self.agreement_rate
    total = count
    return nil if total.zero?

    (where(agreed: true).count.to_f / total * 100).round(2)
  end

  def primary_endpoint = primary_route.to_h["endpoint"]
  def shadow_endpoint = shadow_route.to_h["endpoint"]

  # The family's category names for these categorize comparisons' values, by id.
  def self.category_names(comparisons, family)
    ids = comparisons.flat_map { [ _1.primary_value, _1.shadow_value ] }.compact
    family.categories.where(id: ids).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  # A categorize comparison's category for `side` (:primary or :shadow): the category's name, or
  # the name a migrated row recorded; nil for no category.
  def category_name(side, names)
    names[public_send(:"#{side}_value").to_s].presence || metadata.to_h["#{side}_category_name"].presence
  end
end
