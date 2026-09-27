# frozen_string_literal: true

class BitcoinWalletAccount < ApplicationRecord
  belongs_to :onchain_wallet_item
  belongs_to :account
  belongs_to :security
  delegate :family, to: :onchain_wallet_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_many :bitcoin_wallet_sources, dependent: :destroy
  has_many :bitcoin_wallet_addresses, dependent: :destroy
  has_many :bitcoin_wallet_transactions, dependent: :destroy

  enum :status, { discovering: "discovering", preview: "preview", active: "active", failed: "failed" }, prefix: true
  validates :account_id, uniqueness: true
  validate :eligible_account
  scope :linked, -> { joins(:account_provider) }

  # Return the latest complete confirmed-plus-mempool balance in BTC, using
  # decimal arithmetic to preserve individual satoshis.
  def quantity
    balance_sats.to_d / 100_000_000
  end

  # Expose the Crypto account to provider setup only after a link exists;
  # a discovery preview must not appear as a connected account.
  def current_account
    account if account_provider.present?
  end

  # Prepare quotes before locking, then link a complete preview and reconcile
  # its BTC quantity without changing cash or importing preconnection transfers.
  # Repeated calls keep the existing link and baseline.
  def connect!
    processor = BitcoinWalletAccount::Processor.new(self)
    processor.prepare_prices
    with_lock do
      return if account_provider.present?
      raise ArgumentError, "Complete wallet discovery before connecting" unless status_preview? && last_synced_at.present?

      account.lock!
      create_account_provider!(account: account)
      account.account_providers.reset
      bitcoin_wallet_transactions.update_all(baseline: true)
      update!(baseline_at: Time.current, baseline_sats: balance_sats,
        baseline_cash_balance: account.cash_balance, status: :active)
      record_reconciliation!
      processor.process(prepare_prices: false)
    end
  end

  # Remove tracking and its provider link while retaining the account's latest
  # holdings and cash-neutral ledger entries for continued manual accounting.
  def disconnect!
    with_lock do
      # The latest quantities remain available as manual holdings, and entries
      # retain their provenance. Nothing owned by the user is deleted.
      account_provider&.destroy!
      destroy! unless destroyed?
    end
  end

  # Report a failed, missing or more-than-two-hours-old complete wallet read.
  def stale?
    status_failed? || last_synced_at.nil? || last_synced_at < 2.hours.ago
  end

  # Reopen each HD branch's unused gap after its highest used address, preserving
  # cached addresses and allowing subsequent receives and change to be found.
  def restart_discovery!
    bitcoin_wallet_sources.where(kind: "bip84").each do |source|
      state = [ 0, 1 ].to_h do |branch|
        highest = bitcoin_wallet_addresses.where(bitcoin_wallet_source: source, branch: branch, used: true).maximum(:address_index)
        [ branch.to_s, { "index" => highest ? highest + 1 : 0, "gap" => 0 } ]
      end
      source.update!(discovery: state)
    end
  end

  # Queue discovery of a new source set; an existing connection must reconcile
  # the resulting quantity rather than report previously held funds as income.
  def sources_changed!
    update!(status: :discovering, needs_reconciliation: account_provider.present?)
    restart_discovery!
    BitcoinWalletSyncJob.perform_later(self)
  end

  # Align the dated BTC trade journal with the authoritative quantity through a
  # zero-cash transfer. Ignore future trades and leave earlier entries intact.
  def record_reconciliation!
    recorded = account.trades.where(security: security).joins(:entry).where("entries.date <= ?", Date.current).sum(:qty)
    difference = quantity - recorded
    return if difference.zero?

    price = BitcoinWalletAccount::Portfolio.price(security, account.currency, Date.current) || 0
    Account::ProviderImportAdapter.new(account).import_trade(
      security: security, quantity: difference, price: price, amount: 0, currency: account.currency,
      date: Date.current, source: "bitcoin_wallet_reconciliation",
      external_id: "bitcoin_wallet_#{id}_reconciliation_#{SecureRandom.uuid}",
      name: I18n.t("bitcoin_wallets.reconciliation", locale: account.family.locale),
      activity_label: Trade::TRANSFER_LABEL
    )
  end

  private
    # Restrict the publisher to a same-family Crypto account and BTC security
    # without another provider already owning that position.
    def eligible_account
      return if account.nil? || onchain_wallet_item.nil?
      errors.add(:account, :invalid) unless account.family_id == onchain_wallet_item.family_id && account.accountable_type == "Crypto"
      return if security.nil?
      errors.add(:security, :invalid) unless security.ticker.to_s.upcase.match?(/\A(?:CRYPTO:)?(?:BTC|XBT)(?:-?USD)?\z/)
      competing = account.holdings.where(security: security).where.not(account_provider_id: nil)
      competing = competing.where.not(account_provider_id: account_provider.id) if account_provider
      errors.add(:security, "already has a provider") if competing.exists?
    end
end
