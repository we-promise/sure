# frozen_string_literal: true

# Everything one chain adapter can see for one address: the assets currently
# held, and the movements that produced them. This is the only shape the
# importer, processor and UI ever consume, which is what keeps them free of
# per-chain branches.
module Onchain
  Snapshot = Data.define(:assets, :movements, :history_truncated) do
    # Defaulted, so a chain that reads all of an address's history in one go says
    # nothing about truncation.
    def initialize(assets:, movements:, history_truncated: false)
      super
    end

    def self.empty
      new(assets: [], movements: [])
    end

    def history_truncated?
      history_truncated == true
    end

    # Movements belonging to a given asset. Tokens match on contract; native
    # assets match on symbol among the movements that carry no contract.
    def movements_for(asset)
      if asset.contract_key.present?
        movements.select { |movement| movement.contract_key == asset.contract_key }
      else
        movements.select do |movement|
          movement.contract_key.nil? && movement.symbol.to_s.casecmp?(asset.symbol.to_s)
        end
      end
    end

    def find_asset(kind:, contract: nil)
      assets.find do |asset|
        asset.kind == kind && asset.contract_key == contract.presence&.downcase
      end
    end
  end
end
