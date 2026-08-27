class PlaidTransactionsRefreshPollJob < ApplicationJob
  queue_as :high_priority

  POLL_INTERVAL = 30.seconds
  MAX_ATTEMPTS = 6

  def perform(plaid_item, cursor:, attempts_remaining: MAX_ATTEMPTS)
    plaid_item.reload
    return if plaid_item.next_cursor != cursor

    transactions = plaid_item.plaid_provider.get_transactions(
      plaid_item.access_token,
      next_cursor: cursor
    )

    if transactions.cursor != cursor
      plaid_item.sync_later
    elsif attempts_remaining.to_i > 1
      self.class
        .set(wait: POLL_INTERVAL)
        .perform_later(plaid_item, cursor: cursor, attempts_remaining: attempts_remaining.to_i - 1)
    else
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Plaid transaction refresh completed without advancing the transaction cursor",
        source: self.class.name,
        provider_key: "plaid",
        family: plaid_item.family
      )

      plaid_item.sync_later
    end
  rescue => error
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "warn",
      message: "Plaid transaction refresh polling failed; falling back to a normal sync",
      source: self.class.name,
      provider_key: "plaid",
      family: plaid_item.family,
      metadata: { error_class: error.class.name }
    )

    plaid_item.sync_later
  end
end
