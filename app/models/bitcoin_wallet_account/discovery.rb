# frozen_string_literal: true

class BitcoinWalletAccount::Discovery
  MAX_ADDRESSES = 200
  class Conflict < StandardError; end
  class AddressMismatch < StandardError; end

  # Allocate a per-run HD address budget and use the supplied explorer client.
  # Address derivation remains local to the wallet's public keys.
  def initialize(wallet, provider:, tip: nil)
    @wallet = wallet
    @provider = provider
    @remaining = MAX_ADDRESSES
    @tip = tip
  end

  # Remember manual sources and resume HD scans from saved checkpoints.
  # Return whether every source has completed both branch gaps.
  def perform
    wallet.bitcoin_wallet_sources.each do |source|
      if source.kind == "address"
        publish(source, nil, [ [ source.receive_address, {} ] ])
      else
        scan(source)
      end
    end
    wallet.bitcoin_wallet_sources.reload.all?(&:discovery_complete?)
  end

  # Extend only branches where a new block shortened the trailing unused gap.
  # The caller holds the wallet lock, so a source reset cannot race this update.
  def extend_gaps!(addresses, tip:)
    wallet.bitcoin_wallet_sources.where(kind: "bip84").each do |source|
      state = source.discovery.deep_dup
      wallet.bitcoin_wallet_addresses.where(bitcoin_wallet_source: source, address: addresses.to_a, used: false)
        .pluck(:branch, :address_index).each do |branch, index|
          cursor = state[branch.to_s]
          next unless cursor && cursor["index"].present?

          cursor["index"] = [ cursor["index"], index + 1 ].max
          gap = cursor["index"] - index - 1
          next unless gap < cursor["gap"]

          cursor.merge!("gap" => gap, "complete" => false)
        end
      state["tip_hash"] = tip
      source.update!(discovery: state) if state != source.discovery
    end
    wallet.bitcoin_wallet_sources.reload.all?(&:discovery_complete?)
  end

  def claims_valid?
    wallet.bitcoin_wallet_sources.where(kind: "bip84").all? { |source| valid_claim?(source) }
  end

  private
    attr_reader :wallet, :provider

    # Scan receive and change branches up to the remaining job budget, counting
    # historical or mempool activity as usage even when an address is empty.
    # A completed scan must contain this source's independently supplied address.
    def scan(source)
      original = source.discovery
      # Older in-progress cursors have no proof of which blocks they covered.
      unanchored_progress = @tip && !original.key?("tip_hash") &&
        original.values_at("0", "1").compact.any? { |cursor| cursor.key?("complete") }
      state = unanchored_progress ? {} : original.deep_dup
      state["tip_hash"] ||= @tip if @tip
      # A scan from nothing covers the full gap, so the daily rescan counts from it.
      state["full_scan_at"] ||= Time.current.iso8601 if state.values_at("0", "1").none?
      found = []
      [ 0, 1 ].each do |branch|
        cursor = state.fetch(branch.to_s, { "index" => 0, "gap" => 0 })
        next if cursor["complete"]

        while @remaining.positive? && cursor["gap"] < source.gap_limit
          index = cursor["index"]
          cached = wallet.bitcoin_wallet_addresses.find_by(bitcoin_wallet_source: source, branch: branch, address_index: index)
          address = cached&.address || source.public_key.address(branch, index)
          summary = provider.get_address(address)
          used = %w[chain_stats mempool_stats].sum { |key| summary.fetch(key).fetch("tx_count") }.positive?
          found << [ address, { source: source, branch: branch, index: index, used: used } ]
          cursor["gap"] = used ? 0 : cursor["gap"] + 1
          cursor["index"] += 1
          @remaining -= 1
        end
        cursor["complete"] = cursor["gap"] >= source.gap_limit
        state[branch.to_s] = cursor
      end
      return unless publish(source, original, found) { source.update!(discovery: state) }

      if !@tip && source.discovery_complete? && !valid_claim?(source)
        raise AddressMismatch, "The receive address does not match this BIP84 account within the selected gap limit"
      end
    end

    def valid_claim?(source)
      claims = wallet.bitcoin_wallet_addresses.where(bitcoin_wallet_source_id: source.id)
      return true if claims.exists?(address: source.receive_address)

      # Earlier runs already committed this key's addresses; a wrong key must not keep them.
      claims.delete_all
      false
    end

    # Write a scan's addresses and checkpoint only while its source still exists
    # unchanged, so a source removed, reset or rekeyed during provider reads stays so.
    def publish(source, original, found)
      wallet.with_lock do
        current, fingerprint = BitcoinWalletSource.where(id: source.id).pick(:discovery, :fingerprint)
        return false if current.nil? || (original && current != original) || fingerprint != source.fingerprint

        found.each { |address, attributes| remember(address, **attributes) }
        yield if block_given?
      end
      true
    end

    # Cache an address once within the aggregate, retain any prior used marker,
    # and reject overlap with other household wallet accounts.
    def remember(address, source: nil, branch: nil, index: nil, used: false)
      wallet.family.with_onchain_address_lock(Onchain::Chains::BITCOIN, address) do
        row = wallet.bitcoin_wallet_addresses.find_or_initialize_by(address: address)
        raise Conflict, "An address is already tracked by another account" if row.conflicts?

        row.assign_attributes(branch: branch, address_index: index, bitcoin_wallet_source: source) if source
        row.used = used || row.used
        row.save! if row.changed?
      end
    end
end
