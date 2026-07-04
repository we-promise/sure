# frozen_string_literal: true

class WiseItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_token, deterministic: true
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_token, presence: true, unless: :scheduled_for_deletion?

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :wise_accounts, dependent: :destroy
  has_many :accounts, through: :wise_accounts

  scope :active,       -> { where(scheduled_for_deletion: false) }
  scope :syncable,     -> { active.where.not(api_token: nil) }
  scope :ordered,      -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def syncer
    WiseItem::Syncer.new(self)
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_wise_data(sync: nil)
    provider = wise_provider
    unless provider
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Cannot import: Wise provider is not configured",
        source: self.class.name,
        provider_key: "wise",
        family: family,
        metadata: { wise_item_id: id }
      )
      raise StandardError, I18n.t("wise_items.errors.provider_not_configured")
    end

    WiseItem::Importer.new(self, wise_provider: provider, sync: sync).import
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Failed to import data",
      source: self.class.name,
      provider_key: "wise",
      family: family,
      metadata: { wise_item_id: id, error_class: e.class.name, error_message: e.message }
    )
    raise
  end

  def process_accounts
    return [] if wise_accounts.empty?

    linked_wise_accounts.includes(account_provider: :account).map do |wise_account|
      result = WiseAccount::Processor.new(wise_account).process
      { wise_account_id: wise_account.id, success: true, result: result }
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process account",
        source: self.class.name,
        provider_key: "wise",
        family: family,
        account_provider: wise_account.account_provider,
        metadata: { wise_item_id: id, wise_account_id: wise_account.id, error_class: e.class.name, error_message: e.message }
      )
      { wise_account_id: wise_account.id, success: false, error: e.message }
    end
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
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to schedule sync for account",
        source: self.class.name,
        provider_key: "wise",
        family: family,
        account: account,
        metadata: { wise_item_id: id, account_id: account.id, error_class: e.class.name, error_message: e.message }
      )
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def upsert_wise_snapshot!(snapshot)
    update!(raw_payload: snapshot)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def linked_wise_accounts
    wise_accounts.joins(:account_provider)
  end

  def unlinked_wise_accounts
    wise_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total  = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total == 0
      I18n.t("wise_items.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("wise_items.sync_status.synced", count: linked)
    else
      I18n.t("wise_items.sync_status.synced_with_setup", linked: linked, unlinked: unlinked)
    end
  end

  def linked_accounts_count
    linked_wise_accounts.count
  end

  def unlinked_accounts_count
    unlinked_wise_accounts.count
  end

  def total_accounts_count
    wise_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    [ { "name" => "Wise", "domain" => "wise.com" } ]
  end

  def institution_summary
    institutions = connected_institutions
    if institutions.empty?
      I18n.t("wise_items.institution_summary.none")
    else
      I18n.t("wise_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    api_token.present?
  end
end
