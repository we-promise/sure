class GstOutwardLine < ApplicationRecord
  GSTR1_TABLE_CODES = %w[4A 4B 4C 5A 5B 6A 6B 6C 7 9A 9B 9C 12-B2B 12-B2C].freeze
  MONETARY_AMOUNT_ATTRIBUTES = %i[taxable_value igst cgst sgst_ugst cess].freeze

  belongs_to :family
  belongs_to :tax_workbook_import

  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :tax_period_month, :gstin, :gstr1_table_code, :invoice_no, :invoice_date, presence: true
  validates :gstr1_table_code, inclusion: { in: GSTR1_TABLE_CODES }, allow_blank: true
  validates :gstin, length: { maximum: 15 }
  validates :recipient_gstin_or_uin, length: { maximum: 15 }, allow_blank: true
  validates :rate_pct, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates(*MONETARY_AMOUNT_ATTRIBUTES, numericality: true)
  validate :monetary_amounts_non_negative_for_regular_invoices
  validate :tax_workbook_import_belongs_to_family

  private
    def monetary_amounts_non_negative_for_regular_invoices
      return if allows_negative_monetary_amounts?

      MONETARY_AMOUNT_ATTRIBUTES.each do |attribute|
        value = public_send(attribute)
        next if value.blank? || value >= 0

        errors.add(attribute, "must be greater than or equal to 0 for regular invoices")
      end
    end

    def allows_negative_monetary_amounts?
      is_credit_note? || is_debit_note?
    end

    def tax_workbook_import_belongs_to_family
      return if tax_workbook_import.blank? || family.blank? || tax_workbook_import.family_id == family_id

      errors.add(:tax_workbook_import, "must belong to the same family")
    end
end
