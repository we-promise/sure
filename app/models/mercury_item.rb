class MercuryItem < ApplicationRecord
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
  if encryption_ready?
    encrypts :token, deterministic: true
  end

  validates :name, presence: true
  validates :token, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :mercury_accounts, dependent: :destroy
  has_many :accounts, through: :mercury_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # TODO: Implement data import from provider API
  # This method should fetch the latest data from the provider and import it.
  # May need provider-specific validation (e.g., session validity checks).
  # See LunchflowItem#import_latest_lunchflow_data or EnableBankingItem#import_latest_enable_banking_data for examples.
  def import_latest_mercury_data
    provider = mercury_provider
    unless provider
      Rails.logger.error "MercuryItem #{id} - Cannot import: provider is not configured"
      raise StandardError.new("Mercury provider is not configured")
    end

    # TODO: Add any provider-specific validation here (e.g., session checks)
    MercuryItem::Importer.new(self, mercury_provider: provider).import
  rescue => e
    Rails.logger.error "MercuryItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # TODO: Implement account processing logic
  # This method processes linked accounts after data import.
  # Customize based on your provider's data structure and processing needs.
  def process_accounts
    return [] if mercury_accounts.empty?

    results = []
    mercury_accounts.joins(:account).merge(Account.visible).each do |mercury_account|
      begin
        result = MercuryAccount::Processor.new(mercury_account).process
        results << { mercury_account_id: mercury_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "MercuryItem #{id} - Failed to process account #{mercury_account.id}: #{e.message}"
        results << { mercury_account_id: mercury_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # TODO: Customize sync scheduling if needed
  # This method schedules sync jobs for all linked accounts.
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
        Rails.logger.error "MercuryItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_mercury_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  # TODO: Customize sync status summary if needed
  # Some providers use latest_sync.sync_stats, others use count methods directly.
  # See SimplefinItem#sync_status_summary or EnableBankingItem#sync_status_summary for examples.
  def sync_status_summary
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
    mercury_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    mercury_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    mercury_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  # TODO: Customize based on how your provider stores institution data
  # SimpleFin uses org_data, others use institution_metadata.
  # Adjust the field name and key lookups as needed.
  def connected_institutions
    mercury_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  # TODO: Customize institution summary if your provider has special fields
  # EnableBanking uses aspsp_name as a fallback, for example.
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
    token.present?
  end

  def effective_base_url
    base_url.presence || "https://api.mercury.com/api/v1"
  end
end
