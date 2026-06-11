class Gst3bSummary < ApplicationRecord
  belongs_to :family
  belongs_to :tax_workbook_import

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :gstin, :section_code, presence: true
  validates :gstin, length: { maximum: 15 }
  validates :taxable_value, :igst, :cgst, :sgst_ugst, :cess, :interest, :late_fee,
            numericality: { greater_than_or_equal_to: 0 }
end
