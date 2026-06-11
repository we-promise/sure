class GstOutwardLine < ApplicationRecord
  GSTR1_TABLE_CODES = %w[4A 4B 4C 5A 5B 6A 6B 6C 7 9A 9B 9C 12-B2B 12-B2C].freeze

  belongs_to :family
  belongs_to :tax_workbook_import

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :gstin, :gstr1_table_code, :invoice_no, :invoice_date, presence: true
  validates :gstr1_table_code, inclusion: { in: GSTR1_TABLE_CODES }, allow_blank: true
  validates :gstin, length: { maximum: 15 }
  validates :recipient_gstin_or_uin, length: { maximum: 15 }, allow_blank: true
  validates :rate_pct, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :taxable_value, :igst, :cgst, :sgst_ugst, :cess,
            numericality: { greater_than_or_equal_to: 0 }
  validate :tax_workbook_import_belongs_to_family

  private
    def tax_workbook_import_belongs_to_family
      return if tax_workbook_import.blank? || family.blank? || tax_workbook_import.family_id == family_id

      errors.add(:tax_workbook_import, "must belong to the same family")
    end
end
