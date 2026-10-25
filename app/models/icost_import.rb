require "digest"

# Source documents are independent of Import: reverting a CSV import must never
# cascade through this provenance archive, and deleting it must not delete money.
class IcostImport < ApplicationRecord
  Error = Class.new(StandardError)
  MAX_FILES = 10

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
      locations = IcostRecord.confirmed_locations(user)
      account_mappings = IcostRecord.confirmed_account_mappings(user)
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
        if record.map_coordinates.nil? && (location = locations[record.location_text])
          record.resolution = { "location" => location }
        end
        if (account_id = account_mappings[[ record.account_name, record.currency ]])
          record.resolution = record.resolution.merge("account_id" => account_id)
        end
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

  def process!(user:, recover_all: false)
    self.class.authorize!(family, user)
    raise Error, "not_owner" unless user_id == user.id
    Icost::Reconciler.new(user, import_id: id, recover_all: recover_all).call
    self
  end

  def publish_later(user:)
    self.class.authorize!(family, user)
    raise Error, "not_owner" unless user_id == user.id
    Rails.cache.write(publishing_cache_key, true, expires_in: 10.minutes)
    IcostPublishJob.perform_later(self, user)
  rescue ActiveJob::EnqueueError
    Rails.cache.delete(publishing_cache_key)
    raise Error, "enqueue_failed"
  end

  def publishing?
    Rails.cache.read(publishing_cache_key) == true
  end

  def publishing_cache_key
    "icost:publishing:#{id}"
  end

  def account_groups
    records.where.not(status: "published").where(transaction_type: %w[支出 收入])
      .where("NOT (resolution ? 'duplicate_of_id')")
      .group(:account_name, :currency).count.map do |(name, currency), count|
        { source_account: name, currency: currency, count: count }
      end
  end

  def resolve_accounts!(user:, mappings:)
    self.class.authorize!(family, user)
    raise Error, "not_owner" unless user_id == user.id

    family.with_lock do
      mappings.each do |mapping|
        attrs = mapping.to_h.symbolize_keys
        next if attrs[:account_id].blank?

        records.where.not(status: "published").where(transaction_type: %w[支出 收入],
          account_name: attrs.fetch(:source_account), currency: attrs.fetch(:currency)).find_each do |record|
          record.resolve!(user: user, attributes: { account_id: attrs[:account_id] })
        end
      end
    end
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
