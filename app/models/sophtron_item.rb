# Represents a Sophtron integration item for a family.
#
# A SophtronItem stores Sophtron API credentials and manages the connection
# to a family's Sophtron account. It can have multiple associated SophtronAccounts,
# which represent individual bank accounts linked through Sophtron.
#
# @attr [String] name The display name for this Sophtron connection
# @attr [String] user_id Sophtron User ID (encrypted if encryption is configured)
# @attr [String] access_key Sophtron Access Key (encrypted if encryption is configured)
# @attr [String] base_url Base URL for Sophtron API (optional, defaults to production)
# @attr [String] status Current status: 'good' or 'requires_update'
# @attr [Boolean] scheduled_for_deletion Whether the item is scheduled for deletion
# @attr [DateTime] last_synced_at When the last successful sync occurred
class SophtronItem < ApplicationRecord
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app.
  #
  # Checks both Rails credentials and environment variables for encryption keys.
  #
  # @return [Boolean] true if encryption is properly configured
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured (credentials OR env vars)
  if encryption_ready?
    encrypts :user_id, deterministic: true
    encrypts :access_key, deterministic: true
  end

  validates :name, presence: true
  validates :user_id, presence: true, on: :create
  validates :access_key, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo

  has_many :sophtron_accounts, dependent: :destroy
  has_many :accounts, through: :sophtron_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Imports the latest account and transaction data from Sophtron.
  #
  # This method fetches all accounts and transactions from the Sophtron API
  # and updates the local database accordingly. It will:
  # - Fetch all accounts associated with the Sophtron connection
  # - Create new SophtronAccount records for newly discovered accounts
  # - Update existing linked accounts with latest data
  # - Fetch and store transactions for all linked accounts
  #
  # @return [Hash] Import results with counts of accounts and transactions imported
  # @raise [StandardError] if the Sophtron provider is not configured
  # @raise [Provider::Error] if the Sophtron API returns an error
  def import_latest_sophtron_data
    provider = sophtron_provider
    unless provider
      Rails.logger.error "SophtronItem #{id} - Cannot import: Sophtron provider is not configured (missing API key)"
      raise StandardError.new("Sophtron provider is not configured")
    end

    SophtronItem::Importer.new(self, sophtron_provider: provider).import
  rescue => e
    Rails.logger.error "SophtronItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if sophtron_accounts.empty?

    results = []
    # Only process accounts that are linked and have active status
    sophtron_accounts.joins(:account).merge(Account.visible).each do |sophtron_account|
      begin
        result = SophtronAccount::Processor.new(sophtron_account).process
        results << { sophtron_account_id: sophtron_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "SophtronItem #{id} - Failed to process account #{sophtron_account.id}: #{e.message}"
        results << { sophtron_account_id: sophtron_account.id, success: false, error: e.message }
        # Continue processing other accounts even if one fails
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    # Only schedule syncs for active accounts
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "SophtronItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
        # Continue scheduling other accounts even if one fails
      end
    end

    results
  end

  def upsert_sophtron_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    # Use centralized count helper methods for consistency
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      "No accounts found"
    elsif unlinked_count == 0
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  def linked_accounts_count
    sophtron_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    sophtron_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    sophtron_accounts.count
  end

  def institution_display_name
    # Try to get institution name from stored metadata
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    # Get unique institutions from all accounts
    sophtron_accounts.includes(:account)
                      .where.not(institution_metadata: nil)
                      .map { |acc| acc.institution_metadata }
                      .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  def credentials_configured?
    user_id.present? &&
    access_key.present?
  end

  def effective_base_url
    base_url.presence || "https://api.sophtron.com/api/v2"
  end
end
