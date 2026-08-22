class Tag < ApplicationRecord
  belongs_to :family
  has_many :taggings, dependent: :destroy
  has_many :transactions, through: :taggings, source: :taggable, source_type: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"

  validates :name, presence: true, uniqueness: { scope: :family }
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true

  scope :alphabetically, -> { order(:name, :id) }

  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  UNCATEGORIZED_COLOR = "#737373"

  # Tag name key for i18n
  UNTAGGED_NAME_KEY = "models.tag.untagged"

  # Stable, non-localized filter value for the synthetic "Untagged" option.
  # Using an opaque sentinel (rather than the translated display name) means a real
  # tag can never collide with it, regardless of name or locale.
  UNTAGGED_FILTER_VALUE = "__untagged__"

  class << self
    def untagged
      new(name: I18n.t(UNTAGGED_NAME_KEY), color: UNCATEGORIZED_COLOR)
    end

    # Helper to get the localized name for "Untagged"
    def untagged_name
      I18n.t(UNTAGGED_NAME_KEY)
    end
  end

  def replace_and_destroy!(replacement)
    transaction do
      raise ActiveRecord::RecordInvalid, "Replacement tag cannot be the same as the tag being destroyed" if replacement == self

      if replacement
        taggings.update_all tag_id: replacement.id
      end

      destroy!
    end
  end
end
