# frozen_string_literal: true

# A single inbound or outbound transfer of one asset. `amount` is signed in
# whole units of the asset (positive = received, negative = sent), already
# scaled out of the chain's smallest unit by the adapter.
module Onchain
  Movement = Data.define(:external_id, :symbol, :contract, :amount, :timestamp) do
    # Left as reported: whether case matters depends on the token kind, which a
    # movement does not know. Onchain::Snapshot folds when it compares.
    def contract_key
      contract.presence
    end

    def date
      timestamp&.to_date
    end
  end
end
