require "digest"

# Source documents are independent of Import: reverting a CSV import must never
# cascade through this provenance archive, and deleting it must not delete money.
class IcostImport < ApplicationRecord
  Error = Class.new(StandardError)

  belongs_to :family
  belongs_to :user
  has_many :records, class_name: "IcostRecord", dependent: :destroy

  validates :filename, :file_sha256, :sheet_name, :source_bytes, presence: true
  validates :file_sha256, uniqueness: { scope: :user_id }
  attr_readonly :family_id, :user_id, :filename, :file_sha256, :sheet_name, :headers, :source_bytes

  validate :user_belongs_to_family

  def self.prepare!(family:, user:, bytes:, filename:)
    authorize!(family, user)
    digest = Digest::SHA256.hexdigest(bytes)
    family.with_lock do
      existing = family.icost_imports.find_by(file_sha256: digest)
      raise Error, "source_owned_by_another_user" if existing && existing.user != user
      return existing if existing

      parsed = Icost::FileParser.call(bytes: bytes, filename: filename)
      batch = family.icost_imports.create!(user: user, filename: File.basename(filename),
        file_sha256: digest, sheet_name: parsed.fetch(:sheet_name), headers: parsed.fetch(:headers), source_bytes: bytes)
      parsed.fetch(:rows).each do |row|
        normalized = Icost::Normalizer.call(headers: batch.headers, values: row.fetch(:values))
        fields = normalized.fetch(:attributes).fetch(:raw_fields)
        # Compatible with the original local CSV conversion: absent cells were
        # empty strings; keys sorted by Unicode code point; UTF-8, compact JSON.
        canonical = fields.transform_values { |value| value.nil? ? "" : value }.sort.to_h
        record = batch.records.new(normalized.fetch(:attributes))
        record.assign_attributes(family: family, source_row: row.fetch(:row_number),
          source_id: "icost:#{digest}:#{batch.sheet_name}:#{row.fetch(:row_number)}",
          source_values: row.fetch(:values), row_sha256: Digest::SHA256.hexdigest(JSON.generate(canonical)),
          issues: normalized.fetch(:issues))
        record.stage!(user: user)
      end
      batch
    end
  rescue ActiveRecord::RecordInvalid
    raise Error, "invalid_source_record"
  end

  def publish!(user:)
    self.class.authorize!(family, user)
    raise Error, "not_owner" unless self.user_id == user.id
    records.where(status: "ready").order(:source_row).each { |record| record.publish!(user: user) }
    self
  end

  def self.authorize!(family, user)
    raise Error, "not_authorized" unless user&.family_id == family.id && !user.guest?
  end

  private
    def user_belongs_to_family
      errors.add(:user, :invalid) unless user&.family_id == family_id
    end
end
