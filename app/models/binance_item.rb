# frozen_string_literal: true

class BinanceItem < ApplicationRecord
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  # api_key uses deterministic encryption for querying, api_secret uses standard encryption
  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true

  belongs_to :family

  has_many :binance_accounts, dependent: :destroy
  has_many :accounts, through: :binance_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_binance_data
    provider = binance_provider
    unless provider
      raise StandardError, "Binance credentials not configured"
    end

    BinanceItem::Importer.new(self, binance_provider: provider).import
  rescue => e
    Rails.logger.error "BinanceItem #{id} - Failed to import: #{e.message}"
    raise
  end

  def process_accounts
    Rails.logger.info "BinanceItem #{id} - process_accounts: total binance_accounts=#{binance_accounts.count}"

    return [] if binance_accounts.empty?

    binance_accounts.each do |ba|
      Rails.logger.info(
        "BinanceItem #{id} - binance_account #{ba.id}: " \
        "name='#{ba.name}' " \
        "account_provider=#{ba.account_provider&.id || 'nil'} " \
        "account=#{ba.account&.id || 'nil'}"
      )
    end

    linked = binance_accounts.joins(:account).merge(Account.visible)
    Rails.logger.info "BinanceItem #{id} - found #{linked.count} linked visible accounts to process"

    results = []

    linked.each do |ba|
      begin
        Rails.logger.info "BinanceItem #{id} - processing binance_account #{ba.id}"
        result = BinanceAccount::Processor.new(ba).process
        results << { binance_account_id: ba.id, success: true, result: result }
      rescue => e
        Rails.logger.error "BinanceItem #{id} - Failed to process account #{ba.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        results << { binance_account_id: ba.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "BinanceItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_binance_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total == 0
      I18n.t("binance_items.binance_item.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("binance_items.binance_item.sync_status.all_synced", count: linked)
    else
      I18n.t("binance_items.binance_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  def linked_accounts_count
    binance_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    binance_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    binance_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def credentials_configured?
    api_key.present? && api_secret.present?
  end

  def set_binance_institution_defaults!
    update!(
      institution_name: "Binance",
      institution_domain: "binance.com",
      institution_url: "https://www.binance.com",
      institution_color: "#F0B90B"
    )
  end
end
