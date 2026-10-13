# frozen_string_literal: true

# Shared logic for detecting and handling unidentified card authorization holds.
# Certain ASPSPs return unfinalized card authorization holds with blank provider IDs,
# masked card PAN descriptors instead of merchant/payee names, and sometimes with
# inverted credit/debit signs.
module CardAuthorizationHold
  extend ActiveSupport::Concern

  # Pattern matching masked card authorization descriptors (e.g. "474836xxxxxx6879 003015315475")
  # commonly returned by certain ASPSPs for unfinalized card holds.
  MASKED_CARD_DESCRIPTOR = /\A\d{4,6}[xX*]{4,8}\d{4}(?:\s+\d+)?\z/

  HOLD_TRANSACTION_NAME = "Card Authorization Hold"

  private

    def unidentified_hold?
      return @unidentified_hold if defined?(@unidentified_hold)

      @unidentified_hold = self.class.unidentified_hold?(data)
    end
end
