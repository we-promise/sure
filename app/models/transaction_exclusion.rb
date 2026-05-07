class TransactionExclusion < ApplicationRecord
  belongs_to :family

  enum exclusion_reason: { merged: "merged", dismissed: "dismissed", excluded: "excluded" }

  validates :external_id, :provider, :exclusion_reason, presence: true
  validates :external_id, uniqueness: { scope: [ :family_id, :provider ] }

  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :for_external_ids, ->(ids) { where(external_id: ids) }
end
