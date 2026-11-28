# frozen_string_literal: true

class BitcoinWalletAccount::ChainWindow
  MAX_BLOCKS = 24

  def initialize(provider, owned_addresses)
    @provider = provider
    @owned_addresses = owned_addresses
    @blocks = {}
    @block_addresses = {}
  end

  def height(hash)
    Integer(block(hash).fetch("height"))
  end

  def changed_addresses(from:, to:)
    changed = Set.new
    return changed if from == to

    first_height = height(from)
    last_height = height(to)
    unless (1..MAX_BLOCKS).cover?(last_height - first_height)
      raise BitcoinWalletAccount::Snapshot::ChangedTip, "The wallet's chain window could not be verified"
    end

    intervening = []
    last_height.downto(first_height + 1) do |expected_height|
      unless height(to) == expected_height
        raise BitcoinWalletAccount::Snapshot::ChangedTip, "The wallet's chain window is discontinuous"
      end

      intervening << to
      to = block(to).fetch("previousblockhash")
    end
    unless to == from
      raise BitcoinWalletAccount::Snapshot::ChangedTip, "The wallet's chain window was reorganized"
    end

    intervening.each { |hash| changed.merge(block_addresses(hash)) }
    changed
  end

  private
    def block(hash)
      @blocks[hash] ||= @provider.get_block(hash) ||
        raise(BitcoinWalletAccount::Snapshot::ChangedTip, "A block in the wallet's chain window is unavailable")
    end

    def block_addresses(hash)
      @block_addresses[hash] ||= Set.new.tap do |addresses|
        count = block(hash)["tx_count"]
        @provider.each_block_transaction(hash, count) do |transaction|
          outputs = transaction.fetch("vout") + transaction.fetch("vin").filter_map do |input|
            next if input["is_coinbase"]

            input["prevout"] || raise(Provider::MempoolSpace::ApiError, "Missing Bitcoin block prevout")
          end
          outputs.each do |output|
            address = output["scriptpubkey_address"]
            addresses.add(address) if @owned_addresses.include?(address)
          end
        end
      end
    end
end
