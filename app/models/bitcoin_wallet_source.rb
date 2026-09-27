# frozen_string_literal: true

class BitcoinWalletSource < ApplicationRecord
  include Encryptable

  belongs_to :bitcoin_wallet_account
  encrypts :extended_public_key

  validates :kind, inclusion: { in: %w[address bip84] }
  validates :gap_limit, numericality: { only_integer: true, greater_than_or_equal_to: 20, less_than_or_equal_to: 1000 }
  validates :receive_address, presence: true
  validates :fingerprint, uniqueness: { scope: :bitcoin_wallet_account_id }
  validate :valid_source
  before_validation :normalize_source

  def public_key
    @public_key ||= Onchain::BitcoinPublicKey.new(extended_public_key)
  end

  def discovery_complete?
    kind == "address" || [ 0, 1 ].all? { |branch| discovery.dig(branch.to_s, "complete") == true }
  end

  def reset_discovery!
    update!(discovery: {})
  end

  private
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

    def valid_source
      errors.add(:receive_address, :invalid) unless Onchain::BitcoinPublicKey.valid_address?(receive_address)
      errors.add(:extended_public_key, :invalid) if kind == "address" && extended_public_key.present?
      return if kind != "bip84"

      errors.add(:extended_public_key, :blank) if extended_public_key.blank?
      errors.add(:extended_public_key, "requires configured Active Record encryption") unless ActiveRecordEncryptionConfig.ready?
      public_key if extended_public_key.present?
    rescue Onchain::BitcoinPublicKey::InvalidKey
      errors.add(:extended_public_key, :invalid)
    end
end
