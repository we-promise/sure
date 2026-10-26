# One change of an item's location. A nil location means "no location set";
# deleting a location keeps its moves with that side cleared.
class ValuableItemMove < ApplicationRecord
  belongs_to :valuable_item
  belongs_to :from_location, class_name: "ValuableLocation", optional: true
  belongs_to :to_location, class_name: "ValuableLocation", optional: true

  validates :moved_on, presence: true
end
