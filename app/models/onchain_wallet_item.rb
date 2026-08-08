# frozen_string_literal: true

class OnchainWalletItem < ApplicationRecord
  include Syncable, OnchainWalletItem::Provided, OnchainWalletItem::Unlinking, Encryptable

  ETHEREUM_DATA_PROVIDERS = %w[blockscout etherscan].freeze

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  encrypts :etherscan_api_key, deterministic: true if encryption_ready?
  encrypts :raw_payload if encryption_ready?

  validates :name, presence: true
  validates :ethereum_data_provider, inclusion: { in: ETHEREUM_DATA_PROVIDERS }
  validates :etherscan_api_key, presence: true, if: :etherscan_ethereum_data_provider?

  belongs_to :family
  has_many :onchain_wallet_accounts, dependent: :destroy
  has_many :accounts, through: :onchain_wallet_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  before_validation :normalize_provider_settings

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_onchain_wallet_data
    OnchainWalletItem::Importer.new(self).import
  rescue StandardError => e
    Rails.logger.error "OnchainWalletItem #{id} - Failed to import: #{e.message}"
    raise
  end

  def process_accounts(only_account_ids: nil)
    scope = onchain_wallet_accounts.joins(:account).merge(Account.visible)
    scope = scope.where(id: only_account_ids) if only_account_ids

    scope.map do |wallet_account|
      OnchainWalletAccount::Processor.new(wallet_account).process
      { onchain_wallet_account_id: wallet_account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "OnchainWalletItem #{id} - Failed to process account #{wallet_account.id}: #{e.message}"
      { onchain_wallet_account_id: wallet_account.id, success: false, error: e.message }
    end
  end

  def schedule_account_syncs(only_account_ids: nil, parent_sync: nil, window_start_date: nil, window_end_date: nil)
    scope = accounts.visible
    scope = scope.where(onchain_wallet_accounts: { id: only_account_ids }) if only_account_ids

    scope.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "OnchainWalletItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def upsert_onchain_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    onchain_wallet_accounts.any?
  end

  def credentials_configured?
    !etherscan_ethereum_data_provider? || etherscan_api_key.to_s.strip.present?
  end

  def sync_status_summary
    count = onchain_wallet_accounts.count
    if count.zero?
      I18n.t("onchain_wallet_items.onchain_wallet_item.sync_status.no_accounts")
    else
      I18n.t("onchain_wallet_items.onchain_wallet_item.sync_status.all_synced", count: count)
    end
  end

  def institution_display_name
    institution_name.presence || name.presence || I18n.t("onchain_wallet_items.onchain_wallet_item.fallback_name")
  end

  def set_onchain_institution_defaults!
    update!(
      institution_name: "On-chain Wallets",
      institution_domain: "ethereum.org",
      institution_url: "https://ethereum.org",
      institution_color: "#627EEA"
    )
  end

  private
    def etherscan_ethereum_data_provider?
      ethereum_data_provider == "etherscan"
    end

    def normalize_provider_settings
      self.ethereum_data_provider = ethereum_data_provider.to_s.strip.downcase.presence || "blockscout"
      self.etherscan_api_key = etherscan_api_key.to_s.strip if etherscan_api_key_changed? && !etherscan_api_key.nil?
    end
end
