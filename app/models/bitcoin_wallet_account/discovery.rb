# frozen_string_literal: true

class BitcoinWalletAccount::Discovery
  MAX_ADDRESSES = 200
  class Conflict < StandardError; end
  class AddressMismatch < StandardError; end

  attr_reader :probed_addresses

  # Allocate a per-run HD address budget and use the supplied explorer client.
  # Address derivation remains local to the wallet's public keys.
  def initialize(wallet, provider:, tip: nil)
    @wallet = wallet
    @provider = provider
    @remaining = MAX_ADDRESSES
    @tip = tip
    @probed_addresses = Set.new
  end

  # Remember manual sources and resume HD scans from saved checkpoints.
  # Return whether every source has completed both branch gaps.
  def perform
    wallet.bitcoin_wallet_sources.reload.each do |source|
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
      gap_limit = source.gap_limit
      cursors = original.values_at("0", "1").compact
      stale_gap = cursors.any? { |cursor| cursor["gap_limit"] != gap_limit }
      # Older in-progress cursors have no proof of which blocks they covered.
      unanchored_progress = @tip && !original.key?("tip_hash") && cursors.any? { |cursor| cursor.key?("complete") }
      state = stale_gap || unanchored_progress ? {} : original.deep_dup
      state["tip_hash"] ||= @tip if @tip
      # A scan from nothing covers the full gap, so the daily rescan counts from it.
      state["full_scan_at"] ||= Time.current.iso8601 if state.values_at("0", "1").none?
      found = []
      [ 0, 1 ].each do |branch|
        cursor = state.fetch(branch.to_s, { "index" => 0, "gap" => 0, "gap_limit" => gap_limit })
        next if cursor["complete"]

        while @remaining.positive? && cursor["gap"] < gap_limit
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
        cursor["complete"] = cursor["gap"] >= gap_limit
        state[branch.to_s] = cursor
      end
      invalid_claim = false
      published = publish(source, original, found, gap_limit: gap_limit) do
        source.update!(discovery: state)
        invalid_claim = !@tip && source.discovery_complete? && !valid_claim?(source)
      end
      probed_addresses.merge(found.map(&:first)) if published

      if invalid_claim
        raise AddressMismatch, "The receive address does not match this BIP84 account within the selected gap limit"
      end
    end

    def valid_claim?(source)
      claims = wallet.bitcoin_wallet_addresses.where(bitcoin_wallet_source_id: source.id)
      return true if claims.exists?(address: source.receive_address)

      # Earlier runs already committed this key's addresses; a wrong key must not keep them.
      source.release_addresses
      false
    end

    # Write a scan's addresses and checkpoint only while its source still exists
    # unchanged, so an edit during provider reads cannot restore stale progress.
    def publish(source, original, found, gap_limit: source.gap_limit)
      wallet.with_lock do
        current, fingerprint, current_gap_limit = BitcoinWalletSource.where(id: source.id).pick(:discovery, :fingerprint, :gap_limit)
        return false if current.nil? || (original && current != original) || fingerprint != source.fingerprint || current_gap_limit != gap_limit

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
