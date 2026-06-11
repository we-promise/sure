class GstOutwardLine < ApplicationRecord
  belongs_to :family
  belongs_to :tax_workbook_import

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :gstin, :gstr1_table_code, :invoice_no, :invoice_date, presence: true
  validates :gstin, length: { maximum: 15 }
  validates :recipient_gstin_or_uin, length: { maximum: 15 }, allow_blank: true
  validates :rate_pct, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :taxable_value, :igst, :cgst, :sgst_ugst, :cess,
            numericality: { greater_than_or_equal_to: 0 }
end
