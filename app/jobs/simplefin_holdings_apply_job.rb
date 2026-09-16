# frozen_string_literal: true

class SimplefinHoldingsApplyJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  def self.enqueue_for(source, sync: nil)
    request = SimplefinAccount::HoldingsRequest.capture(source, sync: sync)
    perform_later(source.id, request: request) if request
  end

  # Idempotently materializes holdings for a SimplefinAccount by reading
  # `raw_holdings_payload` and upserting Holding rows by (external_id) or
  # (security,date,currency) via the ProviderImportAdapter used by the
  # SimplefinAccount::Investments::HoldingsProcessor.
  #
  # Capture omits unlinked/non-investment/empty sources. A removed source is a
  # no-op at execution; changed targets or ID-only old jobs require re-enqueue
  # from an admitted current source instead of acquiring today's ownership.
  def perform(simplefin_account_id, request: nil)
    return unless SimplefinAccount.where(id: simplefin_account_id).exists?
    selected = SimplefinAccount::HoldingsRequest.from_token(request, source_id: simplefin_account_id)
    selected.with_source do |sfa|
      apply_holdings(sfa, request: selected)
    end
  end

  private

    def apply_holdings(sfa, request:)
      account = sfa.current_account
      return unless account
      return unless [ "Investment", "Crypto" ].include?(account.accountable_type)

      holdings = Array(sfa.raw_holdings_payload)
      return if holdings.empty?

      SimplefinAccount::Investments::HoldingsProcessor.new(sfa, request: request).process
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged,
        Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => error
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "SimpleFIN deferred holdings application failed", source: self.class.name,
        provider_key: "simplefin", family: sfa.simplefin_item.family, account: account,
        account_provider: sfa.account_provider,
        metadata: { item_id: sfa.simplefin_item_id, simplefin_account_id: sfa.id, error_class: error.class.name })
    end
end
