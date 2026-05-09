class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  validates :source, presence: true
end
