# One item answered twice: by the route that was applied and by its shadow. Written
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

  # Sample size and share of agreement, as a percentage, from one query so a shadow job
  # inserting a row can't give the rate a different sample than the panel reports. Nil rate
  # with no samples; both declining to answer counts as agreement.
  def self.sample_and_agreement
    total, agreed = pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE agreed)"))
    total = total.to_i
    [ total, total.zero? ? nil : (agreed.to_f / total * 100).round(2) ]
  end

  def self.agreement_rate = sample_and_agreement.last

  def primary_endpoint = primary_route.to_h["endpoint"]
  def shadow_endpoint = shadow_route.to_h["endpoint"]

  # What the shadow results show for each side: endpoint and model.
  def primary_label = route_label(primary_route)
  def shadow_label = route_label(shadow_route)

  # The family's category names for these categorize comparisons' values, by id. The values
  # are strings, so one that isn't a UUID is dropped before it reaches the uuid column.
  def self.category_names(comparisons, family)
    ids = comparisons.flat_map { [ _1.primary_value, _1.shadow_value ] }.compact.select { UuidFormat.valid?(_1) }
    return {} if ids.empty?

    family.categories.where(id: ids).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  # A categorize comparison's category for `side` (:primary or :shadow): the category's name, or
  # the name a migrated row recorded; nil for no category.
  def category_name(side, names)
    value = side == :primary ? primary_value : shadow_value
    names[value.to_s].presence || metadata.to_h["#{side}_category_name"].presence
  end

  private
    def route_label(route) = route.to_h.values_at("endpoint", "model").compact.join("/")
end
