class GstHsnSummary < ApplicationRecord
  BUCKETS = %w[B2B B2C].freeze

  belongs_to :family
  belongs_to :tax_workbook_import

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :gstin, :hsn_code, :bucket, presence: true
  validates :bucket, inclusion: { in: BUCKETS }, allow_blank: true
  validates :gstin, length: { maximum: 15 }
  validates :quantity, :taxable_value, :igst, :cgst, :sgst_ugst, :cess,
            numericality: { greater_than_or_equal_to: 0 }
  validate :tax_workbook_import_belongs_to_family

  private
    def tax_workbook_import_belongs_to_family
      return if tax_workbook_import.blank? || family.blank? || tax_workbook_import.family_id == family_id

      errors.add(:tax_workbook_import, "must belong to the same family")
    end
end
