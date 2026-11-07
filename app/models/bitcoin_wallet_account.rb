# frozen_string_literal: true

class BitcoinWalletAccount < ApplicationRecord
  include Syncable

  ROUTINE_LOOKAHEAD = 20
  FULL_RESCAN_INTERVAL = 1.day
  # Tickers a wallet may track.
  BTC_TICKER = /\A(?:CRYPTO:)?(?:BTC|XBT)(?:-?USD)?\z/

  belongs_to :onchain_wallet_item
  belongs_to :account
  belongs_to :security
  delegate :family, to: :onchain_wallet_item
  has_many :bitcoin_wallet_sources, dependent: :destroy
  has_many :bitcoin_wallet_addresses, dependent: :destroy
  has_many :bitcoin_wallet_transactions, dependent: :destroy

  enum :status, { discovering: "discovering", preview: "preview", active: "active", failed: "failed" }, prefix: true
  validates :account_id, uniqueness: true
  validate :eligible_account

  # The last complete explorer read can precede completion of its account sync.
  def last_synced_at
    self[:last_synced_at]
  end

  # Reopen each HD branch after its highest used address, preserving cached
  # addresses so later receives and change are found. Routine syncs probe a
  # standard-size window; the full configured gap is rescanned once a day.
  def restart_discovery!(full: false)
    bitcoin_wallet_sources.where(kind: "bip84").each do |source|
      last_full = source.discovery["full_scan_at"]&.then { |value| Time.zone.parse(value) }
      full_scan = full || last_full.nil? || last_full < FULL_RESCAN_INTERVAL.ago
      skipped = full_scan ? 0 : [ source.gap_limit - ROUTINE_LOOKAHEAD, 0 ].max
      state = [ 0, 1 ].to_h do |branch|
        highest = bitcoin_wallet_addresses.where(bitcoin_wallet_source: source, branch: branch, used: true).maximum(:address_index)
        [ branch.to_s, { "index" => highest ? highest + 1 : 0, "gap" => skipped } ]
      end
      state["full_scan_at"] = full_scan ? Time.current.iso8601 : source.discovery["full_scan_at"]
      source.update!(discovery: state)
    end
  end

  # Queue discovery of a new source set from the start of each branch.
  def sources_changed!
    update!(status: :discovering)
    restart_discovery!(full: true)
    sync_later
  end

  # Publish completion after all account materialization children have finished.
  def perform_post_sync
    account.broadcast_refresh
    onchain_wallet_item.broadcast_sync_complete
  end

  # Refresh the account's existing sync status presentation.
  def broadcast_sync_complete
    account.broadcast_refresh
  end

  private
    # Running reads cannot absorb source edits; independent parents must each
    # retain a child whose completion they can observe.
    def coalescible_syncs(parent_sync: nil)
      scope = syncs.visible.pending
      parent_sync ? scope.where(parent_id: [ nil, parent_sync.id ]) : scope
    end

    # Restrict tracking to a manual same-family Crypto account and a BTC
    # security: the wallet must be the account's only provider.
    def eligible_account
      return if account.nil? || onchain_wallet_item.nil?
      errors.add(:account, :invalid) unless account.family_id == onchain_wallet_item.family_id && account.accountable_type == "Crypto"
      other_links = account.account_providers.where.not(provider_type: self.class.name)
      errors.add(:account, :linked) if other_links.exists? || account.plaid_account_id || account.simplefin_account_id
      return if security.nil?
      errors.add(:security, :invalid) unless security.ticker.to_s.upcase.match?(BTC_TICKER)
    end
end
