# frozen_string_literal: true

class OnchainWalletAccount < ApplicationRecord
  include Encryptable

  CHAINS = %w[bitcoin ethereum].freeze
  ASSET_KINDS = %w[native erc20].freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :onchain_wallet_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :chain, inclusion: { in: CHAINS }
  validates :asset_kind, inclusion: { in: ASSET_KINDS }
  validates :wallet_address, :symbol, :name, :currency, presence: true
  validates :token_contract, presence: true, if: -> { asset_kind == "erc20" }
  validates :token_contract, absence: true, if: -> { asset_kind == "native" }
  validates :symbol, uniqueness: {
    scope: [ :onchain_wallet_item_id, :chain, :wallet_address, :asset_kind, :token_contract ],
    case_sensitive: false
  }

  before_validation :normalize_fields

  def current_account
    account
  end

  def ensure_account_provider!(target_account = nil)
    acct = target_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "OnchainWalletAccount", provider_id: id)
      .tap do |ap|
        ap.account = acct
        ap.save!
      end
  end

  def display_address
    "#{wallet_address.first(8)}...#{wallet_address.last(6)}"
  end

  private
    def normalize_fields
      self.chain = chain.to_s.downcase
      self.asset_kind = asset_kind.to_s.downcase.presence || "native"
      self.wallet_address = wallet_address.to_s.strip
      self.wallet_address = wallet_address.downcase if chain == "ethereum"
      self.token_contract = token_contract.to_s.strip.downcase.presence
      self.symbol = symbol.to_s.strip.upcase
      self.name = name.to_s.strip.presence || symbol
    end
end
