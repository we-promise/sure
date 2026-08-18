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

  def tracks_address?(chain, address)
    onchain_wallet_accounts.for_wallet(chain, address).exists?
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
