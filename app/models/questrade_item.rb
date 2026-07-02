# frozen_string_literal: true

class QuestradeItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  # (encryption_ready? is provided by Encryptable, shared with the other providers).
  if encryption_ready?
    encrypts :refresh_token
  end

  validates :name, presence: true
  validates :refresh_token, presence: true, unless: :scheduled_for_deletion?

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :questrade_accounts, dependent: :destroy
  has_many :accounts, through: :questrade_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(refresh_token: nil) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def syncer
    QuestradeItem::Syncer.new(self)
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Override syncing? to include background activities fetch
  def syncing?
    super || questrade_accounts.where(activities_fetch_pending: true).exists?
  end

  # Import data from provider API
  def import_latest_questrade_data(sync: nil)
    provider = questrade_provider
    unless provider
      Rails.logger.error "QuestradeItem #{id} - Cannot import: provider is not configured"
      raise StandardError, I18n.t("questrade_items.errors.provider_not_configured")
    end

    QuestradeItem::Importer.new(self, questrade_provider: provider, sync: sync).import
  rescue => e
    Rails.logger.error "QuestradeItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  def process_accounts
    return [] if questrade_accounts.empty?

    results = []
    linked_questrade_accounts.includes(account_provider: :account).each do |questrade_account|
      begin
        result = QuestradeAccount::Processor.new(questrade_account).process
        results << { questrade_account_id: questrade_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "QuestradeItem #{id} - Failed to process account #{questrade_account.id}: #{e.message}"
        results << { questrade_account_id: questrade_account.id, success: false, error: e.message }
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
        Rails.logger.error "QuestradeItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_questrade_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_questrade_accounts
    questrade_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_questrade_accounts
    questrade_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("questrade_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("questrade_items.sync_status.synced", count: linked_count)
    else
      I18n.t("questrade_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    questrade_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    questrade_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    questrade_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    questrade_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("questrade_items.institution_summary.none")
    else
      I18n.t("questrade_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    refresh_token.present?
  end
end
