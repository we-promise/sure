# frozen_string_literal: true

class IndexaCapitalActivitiesFetchJob < ApplicationJob
  include IndexaCapitalAccount::DataHelpers
  include Sidekiq::Throttled::Job

  queue_as :default

  MAX_RETRIES = 6
  RETRY_INTERVAL = 10.seconds

  sidekiq_options lock: :until_executed,
                  lock_args_method: ->(args) { args.first },
                  on_conflict: :log

  def perform(indexa_capital_account, start_date: nil, retry_count: 0)
    @indexa_capital_account = indexa_capital_account
    @start_date = start_date || 3.years.ago.to_date
    @retry_count = retry_count

    return clear_pending_flag unless valid_for_fetch?

    fetch_and_process_activities
  rescue => e
    Rails.logger.error("IndexaCapitalActivitiesFetchJob error: #{e.class} - #{e.message}")
    clear_pending_flag
    raise
  end

  private

    def valid_for_fetch?
      return false unless @indexa_capital_account
      return false unless @indexa_capital_account.indexa_capital_item
      return false unless @indexa_capital_account.current_account
      true
    end

    def fetch_and_process_activities
      activities = fetch_activities

      if activities.blank? && @retry_count < MAX_RETRIES
        schedule_retry
        return
      end

      if activities.any?
        merged = merge_activities(existing_activities, activities)
        @indexa_capital_account.upsert_activities_snapshot!(merged)
        @indexa_capital_account.update!(last_activities_sync: Time.current)

        IndexaCapitalAccount::ActivitiesProcessor.new(@indexa_capital_account).process
      end

      clear_pending_flag
      broadcast_updates
    end

    def fetch_activities
      provider = @indexa_capital_account.indexa_capital_item.indexa_capital_provider
      credentials = @indexa_capital_account.indexa_capital_item.indexa_capital_credentials

      return [] unless provider && credentials

      # TODO: Implement API call to fetch activities
      # provider.get_activities(
      #   account_id: @indexa_capital_account.indexa_capital_account_id,
      #   start_date: @start_date,
      #   end_date: Date.current,
      #   **credentials
      # )
      []
    rescue Provider::IndexaCapital::AuthenticationError
      # Re-raise auth errors - they need immediate attention
      raise
    rescue => e
      # Transient errors trigger retry via blank response
      Rails.logger.error("IndexaCapitalActivitiesFetchJob - API error: #{e.message}")
      []
    end

    def existing_activities
      @indexa_capital_account.raw_activities_payload || []
    end

    def merge_activities(existing, new_activities)
      by_id = {}
      existing.each { |a| by_id[activity_key(a)] = a }
      new_activities.each do |a|
        activity_hash = sdk_object_to_hash(a)
        by_id[activity_key(activity_hash)] = activity_hash
      end
      by_id.values
    end

    def activity_key(activity)
      activity = activity.with_indifferent_access if activity.is_a?(Hash)
      activity[:id] || activity["id"] ||
        [ activity[:date], activity[:type], activity[:amount], activity[:symbol] ].join("-")
    end

    def schedule_retry
      Rails.logger.info(
        "IndexaCapitalActivitiesFetchJob - No activities found, scheduling retry " \
        "#{@retry_count + 1}/#{MAX_RETRIES} in #{RETRY_INTERVAL.to_i}s"
      )

      self.class.set(wait: RETRY_INTERVAL).perform_later(
        @indexa_capital_account,
        start_date: @start_date,
        retry_count: @retry_count + 1
      )
    end

    def clear_pending_flag
      @indexa_capital_account.update!(activities_fetch_pending: false)
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
