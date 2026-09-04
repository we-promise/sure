class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy
  has_many :physical_gold_lots, dependent: :nullify

  validates :name, presence: true
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }
end
