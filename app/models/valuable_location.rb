# Where Gems and Bullion items are kept, e.g. "Home safe" or "Bank vault".
# Family-wide, so items in different accounts can share a location.
class ValuableLocation < ApplicationRecord
  belongs_to :family
  has_many :items, class_name: "ValuableItem", foreign_key: :location_id, inverse_of: :location, dependent: :nullify

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :family_id, case_sensitive: false }

  scope :alphabetically, -> { order(Arel.sql("lower(name)")) }
end
