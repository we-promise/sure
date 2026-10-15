class Commodity::ItemMove < ApplicationRecord
  belongs_to :item, class_name: "Commodity::Item"
  belongs_to :from_location, class_name: "Commodity::Location", optional: true
  belongs_to :to_location, class_name: "Commodity::Location", optional: true

  validates :moved_on, presence: true
end
