# frozen_string_literal: true

class WiseItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  enum :profile_type, { personal: "personal", business: "business" }

  if encryption_ready?
    encrypts :token, deterministic: true
    encrypts :raw_payload
  end

  validates :name, :profile_id, :profile_type, presence: true
  validates :token, presence: true, on: :create
  validates :profile_id, uniqueness: { scope: :family_id }

  before_validation :normalize_token

  belongs_to :family

  has_many :wise_accounts, dependent: :destroy
  has_many :accounts, through: :wise_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_wise_data(sync_start_date: nil)
    provider = wise_provider
    unless provider
      Rails.logger.error "WiseItem #{id} - Cannot import: provider not configured"
      raise Provider::Wise::WiseError.new("Wise provider is not configured", :not_configured)
    end

    WiseItem::Importer.new(self, wise_provider: provider, sync_start_date: sync_start_date).import
  rescue => e
    Rails.logger.error "WiseItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if wise_accounts.empty?

    results = []
    wise_accounts.joins(:account).merge(Account.visible).each do |wise_account|
      begin
        result = WiseAccount::Processor.new(wise_account).process
        results << { wise_account_id: wise_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "WiseItem #{id} - Failed to process account #{wise_account.id}: #{e.message}"
        results << { wise_account_id: wise_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Finds interbalance entry pairs (JAR inflow ↔ STANDARD outflow) and links them as Transfers.
  def link_jar_transfers!
    account_ids = accounts.pluck(:id)
    return if account_ids.empty?

    inflow_entries = Entry.where(source: "wise", account_id: account_ids)
                         .where("external_id LIKE 'wise_interbalance_%_inflow'")

    inflow_entries.each do |inflow_entry|
      resource_id = inflow_entry.external_id.sub("wise_interbalance_", "").sub("_inflow", "")
      outflow_entry = Entry.where(source: "wise", account_id: account_ids,
                                  external_id: "wise_interbalance_#{resource_id}_outflow").first

      next unless outflow_entry
      next unless inflow_entry.entryable.is_a?(Transaction) && outflow_entry.entryable.is_a?(Transaction)

      inflow_txn  = inflow_entry.entryable
      outflow_txn = outflow_entry.entryable

      next if Transfer.exists?(inflow_transaction_id: inflow_txn.id)
      next if Transfer.exists?(outflow_transaction_id: outflow_txn.id)

      transfer = Transfer.new(inflow_transaction: inflow_txn, outflow_transaction: outflow_txn, status: "confirmed")
      unless transfer.save
        Rails.logger.warn "WiseItem #{id} - Could not link interbalance #{resource_id}: #{transfer.errors.full_messages.join(", ")}"
      end
    rescue => e
      Rails.logger.error "WiseItem #{id} - Error linking interbalance #{resource_id}: #{e.message}"
    end
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
        Rails.logger.error "WiseItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def credentials_configured?
    token.to_s.strip.present?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total == 0
      I18n.t("wise_items.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("wise_items.sync_status.all_synced", count: linked)
    else
      I18n.t("wise_items.sync_status.partial_setup", synced: linked, pending: unlinked)
    end
  end

  def linked_accounts_count
    wise_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    wise_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    wise_accounts.count
  end

  def institution_display_name
    "Wise"
  end

  def wise_provider
    return nil unless credentials_configured?

    Provider::Wise.new(token.to_s.strip, base_url: Rails.configuration.x.wise.base_url)
  end

  private

    def normalize_token
      self.token = token&.strip
    end
end
