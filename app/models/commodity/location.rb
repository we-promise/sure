# Where items are physically stored (e.g. "Home safe", "Bank deposit box").
# Family-wide so items in different commodity accounts can share locations.
class Commodity::Location < ApplicationRecord
  belongs_to :family
  has_many :items, class_name: "Commodity::Item", foreign_key: :location_id, inverse_of: :location, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :family_id, case_sensitive: false }

  normalizes :name, with: ->(name) { name.squish }

  scope :alphabetically, -> { order(Arel.sql("lower(name)")) }
end
