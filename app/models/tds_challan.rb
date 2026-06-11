class TdsChallan < ApplicationRecord
  belongs_to :family
  belongs_to :tax_workbook_import

  has_many :tds_deductions, dependent: :nullify

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_quarter, :tan, :challan_ref, presence: true
  validates :tan, length: { maximum: 10 }
  validates :tax, :interest, :fee, :penalty, :others, :total_amount,
            numericality: { greater_than_or_equal_to: 0 }
end
