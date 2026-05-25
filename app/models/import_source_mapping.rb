class ImportSourceMapping < ApplicationRecord
  SOURCE_TYPES = %w[Account Category Tag Merchant RecurringTransaction Transaction Budget Security Rule].freeze

  belongs_to :family
  belongs_to :import_session
  belongs_to :target, polymorphic: true, optional: true

  validates :source_type, :source_id, :target_type, :target_id, presence: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :target_type, inclusion: { in: SOURCE_TYPES }, allow_blank: true
  validates :source_type, length: { maximum: 64 }
  validates :source_id, length: { maximum: 255 }
  validates :source_id, uniqueness: { scope: [ :import_session_id, :source_type ] }
  normalizes :source_type, :source_id, with: ->(value) { value.strip.presence }
  validate :family_matches_import_session
  validate :target_exists
  validate :target_matches_family

  private
    def family_matches_import_session
      return if import_session.blank? || family_id == import_session.family_id

      errors.add(:family, "must match import session")
    end

    def target_exists
      return if target_type.blank? || target_id.blank? || !SOURCE_TYPES.include?(target_type)
      return if target.present?

      errors.add(:target, "must exist")
    end

    def target_matches_family
      return if target_type.blank? || !SOURCE_TYPES.include?(target_type)
      return if target.blank?
      return unless target.respond_to?(:family_id)
      return if target.family_id == family_id

      errors.add(:target, "must belong to your family")
    end
end
