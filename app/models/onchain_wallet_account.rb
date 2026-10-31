# frozen_string_literal: true

# One tracked asset, at one address, on one chain. Uniqueness is enforced by
# three partial indexes — one per asset kind — because a native coin is
# identified by its address while a token is identified by its contract.
class OnchainWalletAccount < ApplicationRecord
  belongs_to :onchain_wallet_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :chain, :wallet_address, :asset_kind, :symbol, :currency, presence: true
  validates :quantity, presence: true
  validates :decimals, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :chain_is_registered
  validate :asset_kind_is_valid_for_chain
  validate :contract_matches_asset_kind

  before_validation :normalize_contract_address

  # Native asset first within each wallet, then tokens alphabetically.
  scope :ordered, -> {
    order(:chain, :wallet_address, Arel.sql("CASE WHEN asset_kind = 'native' THEN 0 ELSE 1 END"), :symbol)
  }
  scope :for_wallet, ->(chain, address) { where(chain: chain, wallet_address: address) }
  scope :native, -> { where(asset_kind: Onchain::Chains::NATIVE_KIND) }
  scope :linked, -> { joins(:account_provider) }
  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }

  def native?
    asset_kind == Onchain::Chains::NATIVE_KIND
  end

  # True when the last sync stopped on the history budget rather than on the end
  # of this address's history.
  def history_truncated?
    extra.to_h.dig("onchain_wallet", "history_truncated") == true
  end

  # True when the address holds more tokens than one read surfaces.
  def assets_truncated?
    extra.to_h.dig("onchain_wallet", "assets_truncated") == true
  end

  def chain_definition
    Onchain::Chains.find(chain)
  end

  def chain_label
    chain_definition&.label || chain.to_s.titleize
  end

  def truncated_address
    return wallet_address if wallet_address.to_s.length <= 12

    "#{wallet_address.first(6)}…#{wallet_address.last(4)}"
  end

  def display_name
    "#{symbol} · #{truncated_address}"
  end

  # The asset identity this row stands for, so the importer can match it against
  # a freshly fetched snapshot without caring which chain produced either. Shared
  # with the review screen, which has to agree on what identifies an asset.
  def asset_key
    [ asset_kind, contract_address.presence ].compact.join(":")
  end

  def matches_asset?(asset)
    asset.kind == asset_kind && asset.contract_key == contract_address.presence
  end

  def current_account
    account
  end

  def ensure_account_provider!(target_account = nil)
    acct = target_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: self.class.name, provider_id: id)
      .tap do |link|
        link.account = acct
        link.save!
      end
  end

  private
    # Folded only where case carries no meaning, so an SPL mint is stored as the
    # Base58 key it is rather than an unusable lowercase copy.
    def normalize_contract_address
      value = contract_address.presence
      self.contract_address = if value.nil? || Onchain::Chains.contract_case_sensitive?(asset_kind)
        value
      else
        value.downcase
      end
    end

    def chain_is_registered
      return if chain.blank?
      return if Onchain::Chains.exists?(chain)

      errors.add(:chain, :invalid)
    end

    def asset_kind_is_valid_for_chain
      definition = chain_definition
      return if definition.nil? || asset_kind.blank?
      return if definition.asset_kinds.include?(asset_kind)

      errors.add(:asset_kind, :invalid)
    end

    def contract_matches_asset_kind
      return if asset_kind.blank?

      if native? && contract_address.present?
        errors.add(:contract_address, :present)
      elsif !native? && contract_address.blank?
        errors.add(:contract_address, :blank)
      end
    end
end
