class Gst3bSummary < ApplicationRecord
  SECTION_CODES = %w[3.1(a) 3.1(d) 3.1.1 3.2 4 5 5.1 6.1].freeze

  belongs_to :family
  belongs_to :tax_workbook_import

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :gstin, :section_code, presence: true
  validates :section_code, inclusion: { in: SECTION_CODES }, allow_blank: true
  validates :gstin, length: { maximum: 15 }
  validates :taxable_value, :igst, :cgst, :sgst_ugst, :cess, :interest, :late_fee,
            numericality: { greater_than_or_equal_to: 0 }
  validate :tax_workbook_import_belongs_to_family

  private
    def tax_workbook_import_belongs_to_family
      return if tax_workbook_import.blank? || family.blank? || tax_workbook_import.family_id == family_id

      errors.add(:tax_workbook_import, "must belong to the same family")
    end
end
