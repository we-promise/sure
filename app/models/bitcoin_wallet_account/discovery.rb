# frozen_string_literal: true

class BitcoinWalletAccount::Discovery
  MAX_ADDRESSES = 200
  class Conflict < StandardError; end
  class AddressMismatch < StandardError; end

  # Allocate a per-run HD address budget and use the supplied explorer client.
  # Address derivation remains local to the wallet's public keys.
  def initialize(wallet, provider:)
    @wallet = wallet
    @provider = provider
    @remaining = MAX_ADDRESSES
  end

  # Remember manual sources and resume HD scans from saved checkpoints.
  # Return whether every source has completed both branch gaps.
  def perform
    wallet.bitcoin_wallet_sources.each do |source|
      if source.kind == "address"
        remember(source.receive_address)
      else
        scan(source)
      end
    end
    wallet.bitcoin_wallet_sources.reload.all?(&:discovery_complete?)
  end

  private
    attr_reader :wallet, :provider

    # Scan receive and change branches up to the remaining job budget, counting
    # historical or mempool activity as usage even when an address is empty.
    # A completed scan must contain this source's independently supplied address.
    def scan(source)
      state = source.discovery.deep_dup
      [ 0, 1 ].each do |branch|
        cursor = state.fetch(branch.to_s, { "index" => 0, "gap" => 0 })
        next if cursor["complete"]

        while @remaining.positive? && cursor["gap"] < source.gap_limit
          index = cursor["index"]
          cached = wallet.bitcoin_wallet_addresses.find_by(bitcoin_wallet_source: source, branch: branch, address_index: index)
          address = cached&.address || source.public_key.address(branch, index)
          summary = provider.get_address(address)
          used = %w[chain_stats mempool_stats].sum { |key| summary.fetch(key).fetch("tx_count") }.positive?
          remember(address, source: source, branch: branch, index: index, used: used)
          cursor["gap"] = used ? 0 : cursor["gap"] + 1
          cursor["index"] += 1
          @remaining -= 1
        end
        cursor["complete"] = cursor["gap"] >= source.gap_limit
        state[branch.to_s] = cursor
      end
      source.update!(discovery: state)
      return unless source.discovery_complete?
      return if wallet.bitcoin_wallet_addresses.exists?(address: source.receive_address, bitcoin_wallet_source_id: source.id)

      raise AddressMismatch, "The receive address does not match this BIP84 account within the selected gap limit"
    end

    # Cache an address once within the aggregate, retain any prior used marker,
    # and reject overlap with other household wallet accounts.
    def remember(address, source: nil, branch: nil, index: nil, used: false)
      row = wallet.bitcoin_wallet_addresses.find_or_initialize_by(address: address)
      raise Conflict, "An address is already tracked by another account" if row.conflicts?

      row.assign_attributes(branch: branch, address_index: index, bitcoin_wallet_source: source) if source
      row.used = used || row.used
      row.save! if row.changed?
    end
end
