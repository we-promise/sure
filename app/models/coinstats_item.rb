class CoinstatsItem < ApplicationRecord
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
    encrypts :api_key, deterministic: true
  end

  validates :name, presence: true
  validates :api_key, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo

  has_many :coinstats_accounts, dependent: :destroy
  has_many :accounts, through: :coinstats_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_coinstats_data
    provider = coinstats_provider
    unless provider
      Rails.logger.error "CoinstatsItem #{id} - Cannot import: provider is not configured"
      raise StandardError.new("Coinstats provider is not configured")
    end

    CoinstatsItem::Importer.new(self, coinstats_provider: provider).import
  rescue => e
    Rails.logger.error "CoinstatsItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if coinstats_accounts.empty?

    results = []
    coinstats_accounts.joins(:account).merge(Account.visible).each do |coinstats_account|
      begin
        result = CoinstatsAccount::Processor.new(coinstats_account).process
        results << { coinstats_account_id: coinstats_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "CoinstatsItem #{id} - Failed to process account #{coinstats_account.id}: #{e.message}"
        results << { coinstats_account_id: coinstats_account.id, success: false, error: e.message }
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
        Rails.logger.error "CoinstatsItem #{id} - Failed to schedule sync for wallet #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_coinstats_snapshot!(accounts_snapshot)
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
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      "No accounts found"
    elsif unlinked_count == 0
      "#{linked_count} #{'wallet'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  def linked_accounts_count
    coinstats_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    coinstats_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    coinstats_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    coinstats_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No wallets connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 wallet"
    else
      "#{institutions.count} wallets"
    end
  end

  def credentials_configured?
    api_key.present?
  end
end
