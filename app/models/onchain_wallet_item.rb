# frozen_string_literal: true

# A family's self-custody connection. One item groups every on-chain address
# the family tracks; the addresses and the assets held at them live on
# onchain_wallet_accounts.
class OnchainWalletItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :etherscan_api_key
  end

  validates :name, presence: true

  belongs_to :family

  has_many :onchain_wallet_accounts, dependent: :destroy
  has_many :accounts, through: :onchain_wallet_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  before_validation :strip_credentials

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Self-custody needs no credentials: every chain is readable keyless. The
  # optional Etherscan key only raises Ethereum's rate limit.
  def credentials_configured?
    true
  end

  def import_latest_onchain_data
    OnchainWalletItem::Importer.new(self).import
  end

  # Writes the given rows into the accounts they are linked to. One failing
  # asset must not stop the rest of the wallet from syncing.
  def process_accounts(onchain_accounts)
    onchain_accounts.map do |onchain_account|
      OnchainWalletAccount::Processor.new(onchain_account).process
      { onchain_wallet_account_id: onchain_account.id, success: true }
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process on-chain asset: #{e.class}",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: family,
        account: onchain_account.current_account,
        metadata: {
          onchain_wallet_item_id: id,
          onchain_wallet_account_id: onchain_account.id,
          chain: onchain_account.chain,
          error: e.message
        }
      )
      { onchain_wallet_account_id: onchain_account.id, success: false, error: e.message }
    end
  end

  def schedule_account_syncs(accounts:, parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error("OnchainWalletItem #{id} - failed to schedule sync for account #{account.id}: #{e.message}")
      { account_id: account.id, success: false, error: e.message }
    end
  end

  # [[chain, address], ...] for every address this item tracks.
  def wallet_keys
    onchain_wallet_accounts.distinct.pluck(:chain, :wallet_address)
  end

  def accounts_for_wallet(chain, address)
    onchain_wallet_accounts.for_wallet(chain, address)
  end

  # { [chain, address] => [account, ...] } for the manage UI, ordered so the
  # native asset of each wallet comes first.
  def grouped_accounts
    onchain_wallet_accounts.ordered.group_by { |account| [ account.chain, account.wallet_address ] }
  end

  # Moves every tracked asset at an address to a new one, keeping the rows — and
  # so the accounts, holdings and entries hanging off them — intact. Recreating
  # them would throw away the balance history the user came here for.

  # Stops tracking every asset at an address. The accounts and their history stay
  # behind as manual accounts; only the provider link goes.
  def disconnect_wallet!(chain:, address:)
    accounts_for_wallet(chain, address).destroy_all.size
  end

  def tracks_address?(chain, address)
    onchain_wallet_accounts.for_wallet(chain, address).exists?
  end

  # The accounts a viewer may see on this item, and how many addresses those
  # cover. An item is surfaced on the accounts page as soon as ONE of its
  # accounts is accessible, so a card rendering them all would show a
  # partially-authorised member the names and balances of accounts nobody
  # shared with them. Passing nil means "no restriction", which is what an
  # admin gets.
  #
  # Both read the preloaded associations rather than opening new relations: the
  # accounts page renders one card per item, and a scope here would cost a
  # query per row.
  def accounts_visible_to(allowed_account_ids)
    return accounts.to_a if allowed_account_ids.nil?

    accounts.select { |account| allowed_account_ids.include?(account.id) }
  end

  def address_count_for(visible_accounts)
    visible_ids = visible_accounts.map(&:id).to_set

    onchain_wallet_accounts
      .select { |row| visible_ids.include?(row.account_provider&.account_id) }
      .map { |row| [ row.chain, row.wallet_address ] }
      .uniq
      .size
  end

  def institution_display_name
    institution_name.presence || name
  end

  def set_onchain_institution_defaults!
    update!(institution_name: I18n.t("onchain.institution_name"))
  end

  private
    def strip_credentials
      return unless etherscan_api_key_changed? && !etherscan_api_key.nil?

      self.etherscan_api_key = etherscan_api_key.to_s.strip.presence
    end
end
