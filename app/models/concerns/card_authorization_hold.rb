# frozen_string_literal: true

# Shared logic for detecting and handling unidentified card authorization holds.
# Certain ASPSPs return unfinalized card authorization holds with blank provider IDs,
# masked card PAN descriptors instead of merchant/payee names, and sometimes with
# inverted credit/debit signs.
#
# Including classes must define a class-level unidentified_hold?(raw_transaction_data)
# predicate and a private instance-level data reader returning the raw payload.
module CardAuthorizationHold
  extend ActiveSupport::Concern

  # Pattern matching masked card authorization descriptors (e.g. "474836xxxxxx6879 003015315475")
  # commonly returned by certain ASPSPs for unfinalized card holds.
  MASKED_CARD_DESCRIPTOR = /\A\d{4,6}[xX*]{4,8}\d{4}(?:\s+\d+)?\z/

  HOLD_TRANSACTION_NAME = "Card Authorization Hold"

  # Message for the DebugLogEntry recorded the first time a hold is imported.
  # Kept constant so operators can filter on it in /settings/debug; whether the
  # sign was inverted is recorded in metadata[:sign_inverted].
  HOLD_DIAGNOSTIC_MESSAGE = "Unidentified card authorization hold imported as a pending expense"

  class_methods do
    # True when a single text value is exactly a masked card descriptor.
    #
    # @return [Boolean]
    def masked_card_text?(value)
      value.to_s.strip.match?(MASKED_CARD_DESCRIPTOR)
    end
  end

  private

    def masked_card_text?(value)
      self.class.masked_card_text?(value)
    end

    def unidentified_hold?
      return @unidentified_hold if defined?(@unidentified_hold)

      @unidentified_hold = self.class.unidentified_hold?(data)
    end
end
