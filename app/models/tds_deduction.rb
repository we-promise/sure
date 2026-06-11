class TdsDeduction < ApplicationRecord
  belongs_to :family
  belongs_to :tax_workbook_import
  belongs_to :tds_challan, optional: true

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :tax_period_quarter, :deductor_tan, :deductee_pan_or_aadhaar, :section_code, presence: true
  validates :deductor_tan, length: { maximum: 10 }
  validates :amount_paid, :tds_amount, :surcharge, :cess,
            numericality: { greater_than_or_equal_to: 0 }
  validates :tds_rate_pct, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
