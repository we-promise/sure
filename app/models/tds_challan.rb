class TdsChallan < ApplicationRecord
  COMPONENT_AMOUNT_ATTRIBUTES = %i[tax interest fee penalty others].freeze

  belongs_to :family
  belongs_to :tax_workbook_import

  has_many :tds_deductions, dependent: :restrict_with_error

  normalizes :challan_ref, with: ->(value) { value.to_s.strip.presence }

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_quarter, :tan, :challan_ref, presence: true
  validates :tan, length: { maximum: 10 }
  validates :tax, :interest, :fee, :penalty, :others, :total_amount,
            numericality: { greater_than_or_equal_to: 0 }
  validate :total_amount_matches_components
  validate :tax_workbook_import_belongs_to_family

  private
    def total_amount_matches_components
      return if ([ *COMPONENT_AMOUNT_ATTRIBUTES, :total_amount ]).any? { |attribute| public_send(attribute).nil? }

      expected_total = COMPONENT_AMOUNT_ATTRIBUTES.sum(BigDecimal("0")) { |attribute| public_send(attribute) }
      return if total_amount == expected_total

      errors.add(:total_amount, "must equal tax + interest + fee + penalty + others")
    end

    def tax_workbook_import_belongs_to_family
      return if tax_workbook_import.blank? || family.blank? || tax_workbook_import.family_id == family_id

      errors.add(:tax_workbook_import, "must belong to the same family")
    end
end
