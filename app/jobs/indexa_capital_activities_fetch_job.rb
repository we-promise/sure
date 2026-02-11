# frozen_string_literal: true

class IndexaCapitalActivitiesFetchJob < ApplicationJob
  queue_as :default

  sidekiq_options lock: :until_executed,
                  lock_args_method: ->(args) { args.first },
                  on_conflict: :log

  # Indexa Capital API does not provide an activities/transactions endpoint.
  # This job simply clears the pending flag and broadcasts updates.
  def perform(indexa_capital_account, start_date: nil, retry_count: 0)
    @indexa_capital_account = indexa_capital_account
    return clear_pending_flag unless @indexa_capital_account&.indexa_capital_item

    Rails.logger.info "IndexaCapitalActivitiesFetchJob - No activities endpoint available for Indexa Capital, clearing pending flag"
    clear_pending_flag
    broadcast_updates
  rescue => e
    Rails.logger.error("IndexaCapitalActivitiesFetchJob error: #{e.class} - #{e.message}")
    clear_pending_flag
    raise
  end

  private

    def clear_pending_flag
      @indexa_capital_account&.update!(activities_fetch_pending: false)
    end

    def broadcast_updates
      @indexa_capital_account.current_account&.broadcast_sync_complete
      @indexa_capital_account.indexa_capital_item&.broadcast_replace_to(
        @indexa_capital_account.indexa_capital_item.family,
        target: "indexa_capital_item_#{@indexa_capital_account.indexa_capital_item.id}",
        partial: "indexa_capital_items/indexa_capital_item"
      )
    rescue => e
      Rails.logger.warn("IndexaCapitalActivitiesFetchJob - Broadcast failed: #{e.message}")
    end
end
