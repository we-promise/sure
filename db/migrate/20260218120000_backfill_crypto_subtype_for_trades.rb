# frozen_string_literal: true

class BackfillCryptoSubtypeForTrades < ActiveRecord::Migration[7.2]
  def up
    # Crypto accounts created via the UI before the controller permitted :subtype
    # had subtype NULL, so supports_trades? was false and the Trades API returned 422.
    # Backfill to "exchange" so existing crypto accounts can use the Trades API.
    # Operators can change subtype to "wallet" in the UI if the account is wallet-only.
    say_with_time "Backfilling crypto subtype for existing accounts" do
      Crypto.where(subtype: nil).update_all(subtype: "exchange")
    end
  end

  def down
    # No-op: we cannot distinguish backfilled records from user-chosen "exchange",
    # so reverting would incorrectly clear legitimately set subtypes.
  end
end
