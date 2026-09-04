class PhysicalGoldLot < ApplicationRecord
  INVOICE_MAX_SIZE = 10.megabytes
  ALLOWED_INVOICE_CONTENT_TYPES = %w[
    image/jpeg image/jpg image/png image/gif image/webp
    application/pdf
  ].freeze

  belongs_to :account
  belongs_to :merchant, optional: true

  # A purchase has one supporting invoice or receipt. Keeping it on the lot
  # preserves the proof for the exact weight, purity, merchant, and price.
  has_one_attached :invoice

  validates :description, :acquired_on, :weight, :weight_unit, :karat, presence: true
  validates :weight, numericality: { greater_than: 0 }
  validates :weight_unit, inclusion: { in: Investment::GOLD_WEIGHT_UNITS }
  validates :karat, numericality: { greater_than: 0, less_than_or_equal_to: Investment::MAX_GOLD_KARAT }
  validates :cost_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :making_charge, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :manual_value, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_is_physical_gold
  validate :merchant_belongs_to_account_family
  validate :validate_invoice, if: -> { invoice.attached? }

  def weight_in_grams
    case weight_unit
    when "gram" then weight.to_d
    when "kilogram" then weight.to_d * 1_000
    when "troy_ounce" then weight.to_d * GoldValuation::TROY_OUNCE_GRAMS
    else BigDecimal(0)
    end
  end

  def fine_weight_in_grams
    weight_in_grams * karat.to_d / Investment::MAX_GOLD_KARAT
  end

  def value_for(price_per_troy_ounce)
    return manual_value.to_d if manual_value.present?

    fine_weight_in_grams * price_per_troy_ounce.to_d / GoldValuation::TROY_OUNCE_GRAMS
  end

  def manual_value?
    manual_value.present?
  end

  def total_cost_amount
    cost_amount.to_d + making_charge.to_d
  end

  private
    def validate_invoice
      return unless invoice.blob

      if invoice.byte_size > INVOICE_MAX_SIZE
        errors.add(:invoice, :too_large, max_mb: INVOICE_MAX_SIZE / 1.megabyte)
      end

      unless ALLOWED_INVOICE_CONTENT_TYPES.include?(invoice.content_type)
        errors.add(:invoice, :invalid_format)
      end
    end

    def account_is_physical_gold
      return if account&.investment&.physical_gold?

      errors.add(:account, "must be a physical gold investment")
    end

    def merchant_belongs_to_account_family
      return if merchant.blank? || merchant.is_a?(FamilyMerchant) && merchant.family_id == account&.family_id

      errors.add(:merchant, "must belong to the account family")
    end
end
