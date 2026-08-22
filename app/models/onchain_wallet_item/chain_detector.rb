# frozen_string_literal: true

# Works out which chain an address belongs to.
#
# Address formats are not unique to a chain: one 0x address is valid on every
# EVM network and holds different balances on each, and Bitcoin's Base58 shape
# overlaps Solana's. So candidates come from the address format, and when there
# is more than one, each candidate is asked whether the address is worth tracking
# there — one bounded request per chain, never transfer history.
#
# When several chains answer yes, or none does, the user chooses. Silently
# keeping the first match would link the wrong network and look like a sync bug
# later.
class OnchainWalletItem::ChainDetector
  Result = Data.define(:chain, :candidates, :detected_keys) do
    def resolved?
      chain.present?
    end

    def unrecognized?
      candidates.empty?
    end

    def ambiguous?
      chain.blank? && candidates.any?
    end

    def detected?(candidate)
      detected_keys.include?(candidate.key)
    end
  end

  def initialize(onchain_wallet_item, address)
    @onchain_wallet_item = onchain_wallet_item
    @address = address
  end

  def detect
    candidates = onchain_wallet_item.matching_chain_adapters(address)
    return Result.new(chain: nil, candidates: [], detected_keys: []) if candidates.empty?

    definitions = candidates.map(&:first)
    return Result.new(chain: definitions.first.key, candidates: definitions, detected_keys: []) if candidates.one?

    answers = probe(candidates)
    detected = definitions.select { |definition| answers[definition.key] == true }

    Result.new(
      # One chain answering yes settles it only when every other chain actually
      # answered. If one could not tell, the address may well belong there too,
      # and taking the single yes would link the wrong network for good — so the
      # user is asked, which is the screen an ambiguous answer already produces.
      chain: (detected.one? && answers.values.none?(&:nil?)) ? detected.first.key : nil,
      candidates: definitions,
      detected_keys: detected.map(&:key)
    )
  end

  private
    attr_reader :onchain_wallet_item, :address

    # Concurrently, because the page waits on this: asked in turn, the form's
    # latency is the sum of every chain's, and a 0x address is a candidate on
    # six. The deadline is shared and absolute, so it bounds the whole detection
    # instead of each probe — which is precisely what a per-socket client
    # timeout cannot do.
    def probe(candidates)
      finish_by = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Onchain::DetectionBudget.deadline

      threads = candidates.map do |definition, adapter|
        thread = Thread.new do
          Rails.application.executor.wrap { adapter.has_activity?(address) }
        rescue StandardError => e
          Rails.logger.warn("OnchainWalletItem::ChainDetector - probe failed for #{definition.key}: #{e.class}")
          nil
        end

        [ definition.key, thread ]
      end

      threads.to_h do |key, thread|
        remaining = finish_by - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answer = thread.join([ remaining, 0 ].max) ? thread.value : nil
        thread.kill

        [ key, answer ]
      end
    end
end
