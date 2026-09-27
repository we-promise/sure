# frozen_string_literal: true

class BitcoinWalletAddress < ApplicationRecord
  belongs_to :bitcoin_wallet_account
  belongs_to :bitcoin_wallet_source, optional: true
  belongs_to :family
  before_validation :assign_family
  validates :address, presence: true, uniqueness: { scope: :bitcoin_wallet_account_id }

  def self.tracks?(family:, chain:, address:)
    chain == Onchain::Chains::BITCOIN && where(family: family, address: address).exists?
  end

  def conflicts?
    family = bitcoin_wallet_account.onchain_wallet_item.family
    legacy = family.onchain_wallet_items.joins(:onchain_wallet_accounts)
      .where(onchain_wallet_accounts: { chain: Onchain::Chains::BITCOIN, wallet_address: address })
      .exists?
    grouped = BitcoinWalletAddress.joins(bitcoin_wallet_account: :onchain_wallet_item)
      .where(onchain_wallet_items: { family_id: family.id })
      .where(address: address).where.not(bitcoin_wallet_account_id: bitcoin_wallet_account_id).exists?
    legacy || grouped
  end

  private
    def assign_family
      self.family = bitcoin_wallet_account.onchain_wallet_item.family if bitcoin_wallet_account
    end
end
