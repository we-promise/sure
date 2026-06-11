class TaxWorkbookImport < ApplicationRecord
  XLSX_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  MAX_FILE_SIZE = 10.megabytes

  belongs_to :family
  belongs_to :uploaded_by, class_name: "User", optional: true

  has_one_attached :source_file, dependent: :purge_later

  has_many :gst_outward_lines, dependent: :destroy
  has_many :gst3b_summaries, dependent: :destroy
  has_many :gst_hsn_summaries, dependent: :destroy
  has_many :tds_deductions, dependent: :destroy
  has_many :tds_challans, dependent: :destroy

  enum :status, {
    pending: "pending",
    validated: "validated",
    importing: "importing",
    complete: "complete",
    failed: "failed"
  }, default: :pending, validate: true

  scope :ordered, -> { order(created_at: :desc) }

  validates :filename, :content_type, :checksum, :template_version, presence: true
  validates :byte_size, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE }
  validates :content_type, inclusion: { in: [ XLSX_CONTENT_TYPE ] }
  validates :checksum, length: { is: 64 }
  validates :checksum, uniqueness: { scope: :family_id }
  validates :gstin, length: { maximum: 15 }, allow_blank: true
  validates :tan, length: { maximum: 10 }, allow_blank: true
  validate :json_fields_are_expected_shapes
  validate :uploaded_by_belongs_to_family

  def gst_tax_total
    gst_outward_lines.sum(Arel.sql("igst + cgst + sgst_ugst + cess"))
  end

  def gst_taxable_total
    gst_outward_lines.sum(:taxable_value)
  end

  def tds_total
    tds_deductions.sum(Arel.sql("tds_amount + surcharge + cess"))
  end

  private
    def json_fields_are_expected_shapes
      errors.add(:row_counts, "must be an object") unless row_counts.is_a?(Hash)
      errors.add(:validation_errors, "must be an array") unless validation_errors.is_a?(Array)
      errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
    end

    def uploaded_by_belongs_to_family
      return if uploaded_by.blank? || family.blank? || uploaded_by.family_id == family_id

      errors.add(:uploaded_by, "must belong to the same family")
    end
end
