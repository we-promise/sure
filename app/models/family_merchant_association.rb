class FamilyMerchantAssociation < ApplicationRecord
  belongs_to :family
  belongs_to :merchant

  scope :recently_unlinked, -> { where(unlinked_at: 30.days.ago..).where.not(unlinked_at: nil) }
end
