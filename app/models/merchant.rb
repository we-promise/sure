class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy

  validates :name, presence: true
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  NO_MERCHANT_COLOR = "#737373"

  # Merchant name key for i18n
  NO_MERCHANT_NAME_KEY = "models.merchant.no_merchant"

  class << self
    def no_merchant
      new(name: I18n.t(NO_MERCHANT_NAME_KEY), color: NO_MERCHANT_COLOR)
    end

    # Helper to get the localized name for "No merchant"
    def no_merchant_name
      I18n.t(NO_MERCHANT_NAME_KEY)
    end

    # Returns all possible "No merchant" names across all supported locales
    # Used to detect the no-merchant filter regardless of URL parameter language
    def all_no_merchant_names
      LanguagesHelper::SUPPORTED_LOCALES.map do |locale|
        I18n.t(NO_MERCHANT_NAME_KEY, locale: locale)
      end.uniq
    end
  end
end
