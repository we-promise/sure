# frozen_string_literal: true

class PluggyItem < ApplicationRecord
  include Syncable, Provided, Encryptable, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials if ActiveRecord encryption is configured.
  # `encryption_ready?` is provided by the Encryptable concern (shared with
  # PlaidItem and the other provider items) — it delegates to
  # ActiveRecordEncryptionConfig.explicitly_configured?, which rescues
  # NoMethodError when Rails.application.credentials is nil.
  if encryption_ready?
    encrypts :client_id, deterministic: true
    encrypts :client_secret, deterministic: true
  end

  validates :name, presence: true
  validates :client_id, presence: true, on: :create
  validates :client_secret, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :pluggy_accounts, dependent: :destroy
  has_many :accounts, through: :pluggy_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # The PluggyItem a connect-token should bind to: prefer an already-connected
  # item (one with a `pluggy_item_id`) so the Pluggy Connect widget opens in
  # UPDATE mode for an existing connection; fall back to the first credentialed
  # item for a brand-new (CREATE-mode) connection. Returns nil when the family
  # has no credentials. Single source of truth for "which item does the connect
  # token bind to" so the controller's `@connect_token` and the widget's
  # `is-update` / `item-id` Stimulus values always agree — minting a CREATE-mode
  # token for a family that already has an item is what Pluggy rejects as
  # ITEM_USER_ALREADY_EXISTS.
  def self.preferred_for_connect(family)
    family.pluggy_items.where.not(pluggy_item_id: [ nil, "" ]).ordered.first ||
      family.pluggy_items.where.not(client_id: [ nil, "" ]).ordered.first
  end

  # Intentionally a no-op. Pluggy does NOT expose listing existing connections
  # — its docs state it "is not provided" for security reasons and that callers
  # must track their own itemId (https://docs.pluggy.ai/docs/item). The upstream
  # id must be persisted from the widget / webhook / dashboard flow, not
  # discovered after the fact. Kept as a stable, harmless hook so the single
  # remaining caller — `PluggyItem::Syncer#perform_sync` (sync job, not request
  # thread) — doesn't need to guard; returns the item unchanged so an
  # uncredentialed or unhydrated row surfaces a real `sync_error` in the import
  # phase (`get_item` with a blank id raises Provider::Pluggy::Error) rather than
  # failing the job here. See Provider::Pluggy.
  def self.hydrate_item_id!(item)
    item
  end

  def syncer
    PluggyItem::Syncer.new(self)
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end


  # Import data from provider API
  def import_latest_pluggy_data(sync: nil)
    # `pluggy_provider` (below) unconditionally returns a Provider instance, so a
    # `nil`-guard on it was dead code. Gate on the credential state instead —
    # matches the settings/providers_controller.rb connect-token path, which also
    # checks `credentials_configured?` before touching the provider. Fails fast
    # with a clear message instead of letting the API call fail downstream.
    unless credentials_configured?
      Rails.logger.error "PluggyItem #{id} - Cannot import: provider credentials not configured"
      raise StandardError, I18n.t("pluggy_items.errors.provider_not_configured")
    end

    PluggyItem::Importer.new(self, pluggy_provider: pluggy_provider, sync: sync).import
  rescue => e
    Rails.logger.error "PluggyItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  def process_accounts
    return [] if pluggy_accounts.empty?

    results = []
    linked_pluggy_accounts.includes(account_provider: :account).each do |pluggy_account|
      begin
        result = PluggyAccount::Processor.new(pluggy_account).process
        # Processor#process rescues account-level failures and returns
        # `{ error: }` instead of raising (see PluggyAccount::Processor#process).
        # A blanket `success: true` here hides those failures from Syncer's
        # aggregation (which only counts `success: false`), so a partially failed
        # sync reports total_errors: 0 and marks the item good. Treat a returned
        # error hash as `success: false` so collect_health_stats surfaces it.
        if result.is_a?(Hash) && result.key?(:error)
          results << { pluggy_account_id: pluggy_account.id, success: false, error: result[:error] }
        else
          results << { pluggy_account_id: pluggy_account.id, success: true, result: result }
        end
      rescue => e
        Rails.logger.error "PluggyItem #{id} - Failed to process account #{pluggy_account.id}: #{e.message}"
        results << { pluggy_account_id: pluggy_account.id, success: false, error: e.message }
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
        Rails.logger.error "PluggyItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_pluggy_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_pluggy_accounts
    pluggy_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_pluggy_accounts
    pluggy_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("pluggy_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("pluggy_items.sync_status.synced", count: linked_count)
    else
      I18n.t("pluggy_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    pluggy_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    pluggy_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    pluggy_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    pluggy_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("pluggy_items.institution_summary.none")
    else
      I18n.t("pluggy_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    client_id.present? && client_secret.present?
  end

  def pluggy_provider
    PluggyItem::Provider.new(self)
  end

  def client_user_id
    "pluggy_#{family_id}"
  end

  def webhook_url
    ENV["PLUGGY_WEBHOOK_URL"].presence
  end

  def redirect_url
    ENV["PLUGGY_REDIRECT_URL"].presence || "sureapp://oauth/callback"
  end
end
