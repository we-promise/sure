# One line of a purchase: what was bought, how many, for how much, and in which category.
class PurchaseItem < ApplicationRecord
  belongs_to :purchase, inverse_of: :items
  belongs_to :category, optional: true

  validates :name, presence: true
end
