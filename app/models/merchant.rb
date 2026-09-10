class Merchant < ApplicationRecord
  include Encryptable

  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  # Merchant name key for i18n
  NO_MERCHANT_NAME_KEY = "models.merchant.no_merchant"

  # Stable, non-localized filter value for the synthetic "No merchant" option.
  # Using an opaque sentinel (rather than the translated display name) means a real
  # merchant can never collide with it, regardless of name or locale.
  NO_MERCHANT_FILTER_VALUE = "__no_merchant__"

  # deterministic: true preserves equality lookups (find_by(source:, iban:))
  # and the source+iban uniqueness index. Only meaningful for ProviderMerchant
  # rows in practice, but lives on the shared base class like other
  # provider-specific columns (provider_merchant_id, source).
  if encryption_ready?
    encrypts :iban, deterministic: true
  end

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy

  before_validation :normalize_iban

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

  private
    def normalize_iban
      self.iban = iban.to_s.delete(" ").upcase.presence
    end
end
