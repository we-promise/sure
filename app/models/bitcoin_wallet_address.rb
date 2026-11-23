# frozen_string_literal: true

class BitcoinWalletAddress < ApplicationRecord
  belongs_to :bitcoin_wallet_account
  belongs_to :bitcoin_wallet_source, optional: true
  belongs_to :family
  before_validation :assign_family
  validates :address, presence: true, uniqueness: { scope: :bitcoin_wallet_account_id }

  # Report whether this household already aggregates a Bitcoin address;
  # other-chain addresses are outside this ownership table.
  def self.tracks?(family:, chain:, address:)
    chain == Onchain::Chains::BITCOIN && where(family: family, address: address).exists?
  end

  # Detect an address already claimed by another grouped or legacy single-address
  # Bitcoin account in the same family, while allowing reuse within this wallet.
  def conflicts?
    family = bitcoin_wallet_account.onchain_wallet_item.family
    legacy = family.onchain_wallet_items.active.joins(onchain_wallet_accounts: :account_provider)
      .where(onchain_wallet_accounts: { chain: Onchain::Chains::BITCOIN, wallet_address: address })
      .exists?
    grouped = BitcoinWalletAddress.joins(bitcoin_wallet_account: :onchain_wallet_item)
      .where(onchain_wallet_items: { family_id: family.id })
      .where(address: address).where.not(bitcoin_wallet_account_id: bitcoin_wallet_account_id).exists?
    legacy || grouped
  end

  private
    # Bind uniqueness to the wallet's actual family instead of submitted input.
    def assign_family
      self.family = bitcoin_wallet_account.onchain_wallet_item.family if bitcoin_wallet_account
    end
end
