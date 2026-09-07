# frozen_string_literal: true

# Everything one chain adapter can see for one address: the assets currently
# held, and the movements that produced them. This is the only shape the
# importer, processor and UI ever consume, which is what keeps them free of
# per-chain branches.
module Onchain
  Snapshot = Data.define(:assets, :movements, :history_truncated, :assets_truncated) do
    # Both flags default, so a chain that reads everything an address has in one
    # go says nothing about truncation.
    def initialize(assets:, movements:, history_truncated: false, assets_truncated: false)
      super
    end

    def self.empty
      new(assets: [], movements: [])
    end

    def history_truncated?
      history_truncated == true
    end

    # True when the address holds more tokens than one read surfaces.
    def assets_truncated?
      assets_truncated == true
    end

    # Movements belonging to a given asset. Tokens match on contract; native
    # assets match on symbol among the movements that carry no contract.
    def movements_for(asset)
      if asset.contract.present?
        movements.select { |movement| same_contract?(movement.contract, asset.contract, asset.kind) }
      else
        movements.select do |movement|
          movement.contract.blank? && movement.symbol.to_s.casecmp?(asset.symbol.to_s)
        end
      end
    end

    def find_asset(kind:, contract: nil)
      assets.find do |asset|
        next false unless asset.kind == kind
        next asset.contract.blank? if contract.blank?

        same_contract?(asset.contract, contract, kind)
      end
    end

    private
      # Case matters on some token kinds and not others, and only the kind can say
      # which — see Onchain::Chains::CASE_INSENSITIVE_CONTRACT_KINDS.
      def same_contract?(left, right, kind)
        return false if left.blank? || right.blank?

        Onchain::Chains.contract_case_sensitive?(kind) ? left == right : left.casecmp?(right)
      end
  end
end
