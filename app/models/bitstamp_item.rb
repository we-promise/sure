# frozen_string_literal: true

class BitstampItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :bitstamp_accounts, dependent: :destroy
  has_many :accounts, through: :bitstamp_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  scope :credentials_configured, -> { where.not(api_key: [ nil, "" ]).where.not(api_secret: nil) }

  before_validation :strip_credentials

  def destroy_later
    transaction do
      update!(scheduled_for_deletion: true)
      DestroyJob.perform_later(self)
    end
  end

  def import_latest_bitstamp_data
    provider = bitstamp_provider
    raise StandardError, "Bitstamp credentials not configured" unless provider

    BitstampItem::Importer.new(self, bitstamp_provider: provider).import
  rescue StandardError => e
    Rails.logger.error "BitstampItem #{id} - Failed to import: #{e.full_message}"
    raise
  end

  def process_accounts
    return [] if bitstamp_accounts.empty?

    results = []
    bitstamp_accounts.joins(:account).merge(Account.visible).each do |bitstamp_account|
      begin
        result = BitstampAccount::Processor.new(bitstamp_account).process
        results << { bitstamp_account_id: bitstamp_account.id, success: true, result: result }
      rescue StandardError => e
        Rails.logger.error "BitstampItem #{id} - Failed to process account #{bitstamp_account.id}: #{e.full_message}"
        results << { bitstamp_account_id: bitstamp_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "BitstampItem #{id} - Failed to schedule sync for account #{account.id}: #{e.full_message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def upsert_bitstamp_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def latest_sync_stats
    syncs.ordered.first&.sync_stats || {}
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("bitstamp_items.bitstamp_item.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("bitstamp_items.bitstamp_item.sync_status.all_synced", count: linked)
    else
      I18n.t("bitstamp_items.bitstamp_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  def linked_accounts_count
    bitstamp_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    bitstamp_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    bitstamp_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def credentials_configured?
    api_key.to_s.strip.present? && api_secret.to_s.strip.present?
  end

  def set_bitstamp_institution_defaults!
    update!(
      institution_name: "Bitstamp",
      institution_domain: "bitstamp.net",
      institution_url: "https://www.bitstamp.net",
      institution_color: "#00A86B"
    )
  end

  private

    def strip_credentials
      self.api_key = api_key.to_s.strip if api_key_changed? && !api_key.nil?
      self.api_secret = api_secret.to_s.strip if api_secret_changed? && !api_secret.nil?
    end
end
