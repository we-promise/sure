class PlaidTransactionsRefreshJob < ApplicationJob
  queue_as :high_priority

  def perform(plaid_item)
    cursor = plaid_item.next_cursor

    begin
      plaid_item.plaid_provider.refresh_transactions(plaid_item.access_token)
    rescue => error
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Plaid transaction refresh request did not return successfully; checking for asynchronous completion",
        source: self.class.name,
        provider_key: "plaid",
        family: plaid_item.family,
        metadata: { error_class: error.class.name }
      )
    end

    PlaidTransactionsRefreshPollJob
      .set(wait: PlaidTransactionsRefreshPollJob::POLL_INTERVAL)
      .perform_later(plaid_item, cursor: cursor)
  end
end
