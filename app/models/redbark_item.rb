# frozen_string_literal: true

class RedbarkItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  # Validate on every save, not just create - an update must never blank the key
  validates :api_key, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :redbark_accounts, dependent: :destroy
  has_many :accounts, through: :redbark_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def syncer
    RedbarkItem::Syncer.new(self)
  end

  # Deliberately not transactional - the job must enqueue after the flag commits
  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end


  # Import data from provider API
  def import_latest_redbark_data(sync: nil)
    provider = redbark_provider
    unless provider
      Rails.logger.error "RedbarkItem #{id} - Cannot import: provider is not configured"
      raise StandardError, I18n.t("redbark_items.errors.provider_not_configured")
    end

    RedbarkItem::Importer.new(self, redbark_provider: provider, sync: sync).import
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "Redbark import failed",
      source: self.class.name,
      provider_key: "redbark",
      family: family,
      metadata: { redbark_item_id: id, error_class: e.class.name, error: e.message }
    )
    Rails.logger.error "RedbarkItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  def process_accounts
    return [] if redbark_accounts.empty?

    results = []
    linked_redbark_accounts.includes(account_provider: :account).each do |redbark_account|
      begin
        result = RedbarkAccount::Processor.new(redbark_account).process
        results << { redbark_account_id: redbark_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "error",
          message: "Failed to process Redbark account",
          source: self.class.name,
          provider_key: "redbark",
          family: family,
          metadata: { redbark_account_id: redbark_account.id, error_class: e.class.name, error: e.message }
        )
        results << { redbark_account_id: redbark_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Schedule sync jobs for all linked accounts
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
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "error",
          message: "Redbark account sync scheduling failed",
          source: self.class.name,
          provider_key: "redbark",
          family: family,
          metadata: { redbark_item_id: id, account_id: account.id, error_class: e.class.name, error: e.message }
        )
        Rails.logger.error "RedbarkItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_redbark_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_redbark_accounts
    redbark_accounts.joins(:account_provider)
  end

  # Unlinked accounts still awaiting setup (no AccountProvider link, not skipped by the user)
  def unlinked_redbark_accounts
    redbark_accounts.needs_setup
  end

  def sync_status_summary
    if account_counts[:total] == 0
      I18n.t("redbark_items.sync_status.no_accounts")
    elsif account_counts[:needs_setup] == 0
      I18n.t("redbark_items.sync_status.synced", count: account_counts[:linked])
    else
      I18n.t("redbark_items.sync_status.synced_with_setup", linked: account_counts[:linked], unlinked: account_counts[:needs_setup])
    end
  end

  def linked_accounts_count
    account_counts[:linked]
  end

  def unlinked_accounts_count
    account_counts[:needs_setup]
  end

  def total_accounts_count
    account_counts[:total]
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    redbark_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("redbark_items.institution_summary.none")
    else
      I18n.t("redbark_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    api_key.present?
  end

  private

    # One grouped query instead of separate COUNTs for each of the
    # linked/unlinked/total figures the accounts index partial reads.
    def account_counts
      @account_counts ||= begin
        rows = redbark_accounts
          .left_joins(:account_provider)
          .group(:ignored, Arel.sql("account_providers.id IS NULL"))
          .count

        {
          total: rows.values.sum,
          linked: rows.sum { |(_ignored, unlinked), count| unlinked ? 0 : count },
          needs_setup: rows.sum { |(ignored, unlinked), count| unlinked && !ignored ? count : 0 }
        }
      end
    end
end
