class TdsDeduction < ApplicationRecord
  SECTION_CODES = %w[
    192A 193 194 194A 194B 194BA 194BB 194C 194D 194DA 194EE 194F 194G
    194H 194I 194J 194K 194LA 194LBA 194LBB 194LBC 194N 194O 194P 194Q
    194R 194S
  ].freeze

  belongs_to :family
  belongs_to :tax_workbook_import
  belongs_to :tds_challan, optional: true

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :tax_period_quarter, :deductor_tan, :deductee_pan_or_aadhaar, :section_code, presence: true
  validates :section_code, inclusion: { in: SECTION_CODES }, allow_blank: true
  validates :deductor_tan, length: { maximum: 10 }
  validates :amount_paid, :tds_amount, :surcharge, :cess,
            numericality: { greater_than_or_equal_to: 0 }
  validates :tds_rate_pct, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :tax_workbook_import_belongs_to_family
  validate :tds_challan_matches_import

  private
    def tax_workbook_import_belongs_to_family
      return if tax_workbook_import.blank? || family.blank? || tax_workbook_import.family_id == family_id

      errors.add(:tax_workbook_import, "must belong to the same family")
    end

    def tds_challan_matches_import
      return if tds_challan.blank?

      if family.present? && tds_challan.family_id != family_id
        errors.add(:tds_challan, "must belong to the same family")
      end

      if tax_workbook_import.present? && tds_challan.tax_workbook_import_id != tax_workbook_import_id
        errors.add(:tds_challan, "must belong to the same tax workbook import")
      end
    end
end
