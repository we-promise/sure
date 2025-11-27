# frozen_string_literal: true

class SimplefinHoldingsApplyJob < ApplicationJob
  queue_as :default

  # Idempotently materializes holdings for a SimplefinAccount by reading
  # `raw_holdings_payload` and upserting Holding rows by (external_id) or
  # (security,date,currency) via the ProviderImportAdapter used by the
  # SimplefinAccount::Investments::HoldingsProcessor.
  #
  # Safe no-op when:
  # - the SimplefinAccount is missing
  # - there is no current linked Account
  # - the linked Account is not an Investment/Crypto
  # - there is no raw holdings payload
  def perform(simplefin_account_id)
    sfa = SimplefinAccount.find_by(id: simplefin_account_id)
    return unless sfa

    account = sfa.current_account
    return unless account
    return unless [ "Investment", "Crypto" ].include?(account.accountable_type)

    holdings = Array(sfa.raw_holdings_payload)
    return if holdings.empty?

    begin
      SimplefinAccount::Investments::HoldingsProcessor.new(sfa).process
    rescue => e
      Rails.logger.warn("SimpleFin HoldingsApplyJob failed for SFA=#{sfa.id}: #{e.class} - #{e.message}")
    end
  end
end
