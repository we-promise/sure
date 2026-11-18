class Merchant < ApplicationRecord
  include Encryptable, IbanNormalizable

  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  # Merchant name key for i18n
  NO_MERCHANT_NAME_KEY = "models.merchant.no_merchant"

  # Stable, non-localized filter value for the synthetic "No merchant" option.
  # Using an opaque sentinel (rather than the translated display name) means a real
  # merchant can never collide with it, regardless of name or locale.
  NO_MERCHANT_FILTER_VALUE = "__no_merchant__"

  # Entered by the family on its own merchants only (see
  # FamilyMerchantsController); a ProviderMerchant is shared by every family
  # and never holds one. Not deterministic: an IBAN is never looked up by
  # value in SQL, Account::ProviderImportAdapter compares the family's few
  # merchant IBANs in Ruby.
  if encryption_ready?
    encrypts :iban
  end

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy

  # Declared here rather than on FamilyMerchant so lists mixing both types can preload it.
  has_one_attached :logo, dependent: :purge_later do |attachable|
    attachable.variant :small, resize_to_fill: [ 128, 128 ], convert: :webp, saver: { quality: 80 }, preprocessed: true
  end

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
