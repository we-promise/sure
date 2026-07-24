class SnaptradeItem < ApplicationRecord
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
  # client_id/consumer_key use deterministic encryption (may need querying)
  # snaptrade_user_secret uses non-deterministic (more secure for pure secrets)
  # Note: snaptrade_user_id is not encrypted as it's just an identifier, not a secret
  if encryption_ready?
    encrypts :client_id, deterministic: true
    encrypts :consumer_key, deterministic: true
    encrypts :snaptrade_user_secret
    encrypts :oauth_access_token
    encrypts :oauth_refresh_token
  end

  validates :name, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :snaptrade_accounts, dependent: :destroy
  has_many :linked_accounts, through: :snaptrade_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  # Syncable = active + authorized via OAuth (has an access token).
  # oauth_access_token is non-deterministically encrypted, so it can only be
  # queried with an IS NULL check (never persisted as "" -- see apply_oauth_tokens!).
  scope :syncable, -> { active.where.not(oauth_access_token: nil) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_snaptrade_data(sync: nil)
    provider = snaptrade_provider
    unless provider
      Rails.logger.error "SnaptradeItem #{id} - Cannot import: OAuth not authorized"
      raise StandardError, "SnapTrade is not authorized"
    end

    SnaptradeItem::Importer.new(self, snaptrade_provider: provider, sync: sync).import
  rescue => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if snaptrade_accounts.empty?

    results = []
    # Process only accounts that are linked to a Sure account
    linked_snaptrade_accounts.includes(account_provider: :account).each do |snaptrade_account|
      account = snaptrade_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = SnaptradeAccount::Processor.new(snaptrade_account).process
        results << { snaptrade_account_id: snaptrade_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "SnaptradeItem #{id} - Failed to process account #{snaptrade_account.id}: #{e.message}"
        results << { snaptrade_account_id: snaptrade_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    linked_accounts = accounts.reject { |a| a.pending_deletion? || a.disabled? }
    return [] if linked_accounts.empty?

    results = []
    linked_accounts.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "SnaptradeItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_snaptrade_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  # Persist an OAuth token payload (string keys, as returned by the token endpoint).
  # A rotation response may omit refresh_token; keep the existing one in that case.
  def apply_oauth_tokens!(payload)
    raise ArgumentError, "OAuth token payload missing access_token" if payload["access_token"].blank?

    update!(
      oauth_access_token: payload["access_token"],
      oauth_refresh_token: payload["refresh_token"].presence || oauth_refresh_token,
      oauth_token_type: payload["token_type"].presence || oauth_token_type,
      oauth_scope: payload["scope"].presence || oauth_scope,
      oauth_token_expires_at: payload["expires_in"].present? ? Time.current + payload["expires_in"].to_i.seconds : oauth_token_expires_at
    )
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("snaptrade_item.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("snaptrade_item.sync_status.synced", count: linked_count)
    else
      I18n.t("snaptrade_item.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    snaptrade_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    snaptrade_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    snaptrade_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    snaptrade_accounts
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def oauth_token_active?
    oauth_access_token.present? && (oauth_token_expires_at.blank? || oauth_token_expires_at.future?)
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("snaptrade_item.institution_summary.none")
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || I18n.t("snaptrade_item.institution_summary.count", count: 1)
    else
      I18n.t("snaptrade_item.institution_summary.count", count: institutions.count)
    end
  end

  def oauth_configured?
    oauth_access_token.present?
  end
  alias_method :credentials_configured?, :oauth_configured?

  def fully_configured?
    oauth_configured?
  end

  # Override Syncable#syncing? to also show syncing state when activities are being
  # fetched in the background. This ensures the UI shows the spinner until all data
  # is truly imported, not just when the main sync job completes.
  def syncing?
    super || snaptrade_accounts.where(activities_fetch_pending: true).exists?
  end

  # Get accounts linked via AccountProvider
  def linked_snaptrade_accounts
    snaptrade_accounts.joins(:account_provider)
  end

  # Get all Sure accounts linked to this SnapTrade item
  def accounts
    snaptrade_accounts
      .includes(account_provider: :account)
      .filter_map { |sa| sa.current_account }
      .uniq
  end

  # Get unique brokerages from connected accounts
  def connected_brokerages
    snaptrade_accounts
      .where.not(brokerage_name: nil)
      .pluck(:brokerage_name)
      .uniq
  end

  def brokerage_summary
    brokerages = connected_brokerages
    case brokerages.count
    when 0
      I18n.t("snaptrade_item.brokerage_summary.none")
    when 1
      brokerages.first
    else
      I18n.t("snaptrade_item.brokerage_summary.count", count: brokerages.count)
    end
  end
end
