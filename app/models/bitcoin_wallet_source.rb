# frozen_string_literal: true

class BitcoinWalletSource < ApplicationRecord
  include Encryptable

  belongs_to :bitcoin_wallet_account
  encrypts :extended_public_key
  # A source is replaced by removing it and adding another, which releases the
  # old key's addresses; editing it in place would keep them.
  attr_readonly :kind, :extended_public_key, :receive_address, :fingerprint

  validates :kind, inclusion: { in: %w[address bip84] }
  validates :gap_limit, numericality: { only_integer: true, greater_than_or_equal_to: 20, less_than_or_equal_to: 1000 }
  validates :receive_address, presence: true
  validates :fingerprint, uniqueness: { scope: :bitcoin_wallet_account_id }
  validate :valid_source
  before_validation :normalize_source, on: :create
  before_update :lock_wallet, if: :will_save_change_to_gap_limit?
  before_destroy :lock_wallet, :release_addresses

  # Parse the encrypted-at-rest public key locally and cache its derivation
  # object until the key changes. Invalid key material raises InvalidKey.
  def public_key
    unless @public_key && @parsed_key == extended_public_key
      @public_key = Onchain::BitcoinPublicKey.new(extended_public_key)
      @parsed_key = extended_public_key
    end
    @public_key
  end

  # Manual addresses need no HD scan; extended-key sources require completed
  # unused gaps on both receive and change branches.
  def discovery_complete?
    kind == "address" || %w[0 1].all? do |branch|
      discovery.dig(branch, "complete") == true && discovery.dig(branch, "gap_limit") == gap_limit
    end
  end

  # The caller holds the wallet lock. Keep one row per address even when a
  # manual source and an HD source both claim it.
  def release_addresses
    rows = bitcoin_wallet_account.bitcoin_wallet_addresses
    if kind == "address"
      rows.where(bitcoin_wallet_source_id: nil, address: receive_address).delete_all
    else
      claims = rows.where(bitcoin_wallet_source_id: id)
      manual_addresses = bitcoin_wallet_account.bitcoin_wallet_sources.where(kind: "address").select(:receive_address)
      claims.where(address: manual_addresses).update_all(bitcoin_wallet_source_id: nil, branch: nil, address_index: nil)
      claims.delete_all
    end
  end

  private
    def lock_wallet
      BitcoinWalletAccount.where(id: bitcoin_wallet_account_id).lock.pick(:id)
    end

    # Canonicalize address/key whitespace and derive a duplicate-source identity
    # shared by equivalent xpub/zpub encodings. Validation reports invalid keys.
    def normalize_source
      self.receive_address = Onchain::BitcoinPublicKey.canonical_address(receive_address)
      self.extended_public_key = extended_public_key.to_s.strip.presence
      self.fingerprint = if kind == "bip84" && extended_public_key.present?
        public_key.fingerprint
      else
        Digest::SHA256.hexdigest(receive_address.to_s)
      end
    rescue Onchain::BitcoinPublicKey::InvalidKey
      # Validation reports the failure without persisting any key.
    end

    # Accept checksum-valid public addresses or a supported account-level key
    # with configured encryption. Private material has no permitted source mode.
    def valid_source
      errors.add(:receive_address, :invalid) unless Onchain::BitcoinPublicKey.valid_address?(receive_address)
      errors.add(:extended_public_key, :invalid) if kind == "address" && extended_public_key.present?
      return if kind != "bip84"

      errors.add(:extended_public_key, :blank) if extended_public_key.blank?
      errors.add(:extended_public_key, :encryption_unavailable) unless ActiveRecordEncryptionConfig.ready?
      public_key if extended_public_key.present?
    rescue Onchain::BitcoinPublicKey::InvalidKey
      errors.add(:extended_public_key, :invalid)
    end
end
