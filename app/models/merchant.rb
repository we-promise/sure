class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  # Merchant name key for i18n
  NO_MERCHANT_NAME_KEY = "models.merchant.no_merchant"

  # Stable, non-localized filter value for the synthetic "No merchant" option.
  # Using an opaque sentinel (rather than the translated display name) means a real
  # merchant can never collide with it, regardless of name or locale.
  NO_MERCHANT_FILTER_VALUE = "__no_merchant__"

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy

  validates :name, presence: true
  validates :name, exclusion: { in: [ NO_MERCHANT_FILTER_VALUE ] }
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  class << self
    def no_merchant
      new(name: I18n.t(NO_MERCHANT_NAME_KEY))
    end

    # Helper to get the localized name for "No merchant"
    def no_merchant_name
      I18n.t(NO_MERCHANT_NAME_KEY)
    end
  end

  # The value the transactions-filter checkbox submits for this merchant: the
  # persisted name for a real merchant, or the stable sentinel for the
  # synthetic "No merchant" pseudo-merchant returned by .no_merchant.
  def filter_value
    persisted? ? name : NO_MERCHANT_FILTER_VALUE
  end
end
