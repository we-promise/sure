class ValuableItem < ApplicationRecord
  INVOICE_MAX_SIZE = 10.megabytes
  ALLOWED_INVOICE_CONTENT_TYPES = %w[image/jpeg image/jpg image/png image/gif image/webp application/pdf].freeze
  BULLION_MATERIALS = { "gold" => "XAU", "silver" => "XAG", "platinum" => "XPT", "palladium" => "XPD" }.freeze
  GEMSTONE_MATERIALS = %w[diamond ruby sapphire emerald other].freeze
  ITEM_TYPES = %w[bullion gemstone].freeze
  BULLION_WEIGHT_UNITS = %w[gram troy_ounce kilogram].freeze

  belongs_to :valuable
  has_one :account, through: :valuable
  delegate :id, to: :account, prefix: true
  delegate :family_id, to: :account
  belongs_to :merchant, optional: true
  has_one_attached :invoice

  attr_accessor :skip_queued_valuation_refresh

  before_validation -> { self.currency ||= account&.currency }
  before_validation :set_material_defaults

  validates :description, :acquired_on, :item_type, :material, :weight, :weight_unit, presence: true
  validates :item_type, inclusion: { in: ITEM_TYPES }
  validates :weight, numericality: { greater_than: 0 }
  validates :cost_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :making_charge, :manual_value, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :currency, :account, presence: true
  validates :acquired_on, comparison: { less_than_or_equal_to: -> { Date.current } }, allow_nil: true
  validate :material_matches_item_type
  validate :weight_unit_matches_item_type
  validate :purity_rules
  validate :gemstone_requires_manual_value
  validate :currency_matches_account
  validate :merchant_belongs_to_account_family
  validate :validate_invoice, if: -> { invoice.attached? }

  around_save :serialize_with_valuation
  around_destroy :serialize_with_valuation
  after_save :mark_valuation_pending
  after_destroy :mark_valuation_pending
  after_commit :refresh_valuation_later

  scope :spot_valued, -> { where(item_type: "bullion").where(manual_value: nil) }

  def bullion? = item_type == "bullion"
  def gemstone? = item_type == "gemstone"
  def spot_valued? = bullion? && !manual_value?
  def quote_symbol = BULLION_MATERIALS[material]
  def weight_in_grams = ValuableWeight.in_grams(weight, weight_unit)
  def fine_weight_in_grams = weight_in_grams * purity.to_d / 100
  def value_for(price_per_troy_ounce = nil)
    return manual_value.to_d if manual_value.present?
    return BigDecimal(0) unless spot_valued? && price_per_troy_ounce
    fine_weight_in_grams * price_per_troy_ounce.to_d / ValuableWeight::TROY_OUNCE_GRAMS
  end
  def manual_value? = manual_value.present?
  def total_cost_amount = cost_amount.to_d + making_charge.to_d

  # Import compatibility for the earlier gold-only schema. New forms and
  # exports use percentage purity.
  def karat = (purity.to_d * 24 / 100).round(3)
  def karat=(value)
    self.purity = value.present? ? value.to_d * 100 / 24 : nil
  end

  private
    def set_material_defaults
      self.item_type ||= "bullion"
      self.material ||= bullion? ? "gold" : "diamond"
    end

    def material_matches_item_type
      allowed = bullion? ? BULLION_MATERIALS.keys : GEMSTONE_MATERIALS
      errors.add(:material, :inclusion) unless allowed.include?(material)
    end

    def weight_unit_matches_item_type
      allowed = bullion? ? BULLION_WEIGHT_UNITS : [ "carat" ]
      errors.add(:weight_unit, :inclusion) unless allowed.include?(weight_unit)
    end

    def purity_rules
      if bullion?
        errors.add(:purity, :blank) if purity.blank?
        errors.add(:purity, :invalid) if purity.present? && !(purity.to_d > 0 && purity.to_d <= 100)
      elsif purity.present?
        errors.add(:purity, :not_applicable)
      end
    end

    def gemstone_requires_manual_value
      errors.add(:manual_value, :blank) if gemstone? && manual_value.blank?
    end

    def validate_invoice
      return unless invoice.blob
      errors.add(:invoice, :too_large, max_mb: INVOICE_MAX_SIZE / 1.megabyte) if invoice.byte_size > INVOICE_MAX_SIZE
      errors.add(:invoice, :invalid_format) unless ALLOWED_INVOICE_CONTENT_TYPES.include?(invoice.content_type)
    end

    def currency_matches_account
      errors.add(:currency, :invalid) if account && currency != account.currency
    end

    def serialize_with_valuation
      return yield if destroyed_by_association
      account.with_lock do
        if !destroyed? && currency != account.currency
          errors.add(:currency, :invalid)
          raise ActiveRecord::RecordInvalid, self
        end
        yield
      end
    end

    def mark_valuation_pending
      valuable.update_columns(valuation_pending: true) unless valuable.destroyed? || destroyed_by_association
    end

    def refresh_valuation_later
      return if skip_queued_valuation_refresh || destroyed_by_association || !Valuable.exists?(valuable_id)

      RefreshValuableValuationJob.perform_later(account_id)
    end

    def merchant_belongs_to_account_family
      return if merchant.blank? || merchant.is_a?(FamilyMerchant) && merchant.family_id == account&.family_id
      errors.add(:merchant, :must_belong_to_account_family)
    end
end
