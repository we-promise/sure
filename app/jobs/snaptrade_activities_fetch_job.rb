# Job for fetching SnapTrade activities with retry logic
#
# On fresh brokerage connections, SnapTrade may need 30-60+ seconds to sync
# data from the brokerage. This job handles that delay by rescheduling itself
# instead of blocking the worker with sleep().
#
# Usage:
#   SnaptradeActivitiesFetchJob.perform_later(snaptrade_account, start_date: 5.years.ago.to_date)
#
class SnaptradeActivitiesFetchJob < ApplicationJob
  queue_as :default

  # Prevent concurrent jobs for the same account - only one fetch at a time
  sidekiq_options lock: :until_executed,
                  lock_args_method: ->(args) { [ args.first.id ] },
                  on_conflict: :log

  # Configuration for retry behavior
  RETRY_DELAY = 10.seconds
  MAX_RETRIES = 6

  def perform(snaptrade_account, start_date:, end_date: nil, retry_count: 0)
    end_date ||= Date.current

    Rails.logger.info(
      "SnaptradeActivitiesFetchJob - Fetching activities for account #{snaptrade_account.id}, " \
      "retry #{retry_count}/#{MAX_RETRIES}, range: #{start_date} to #{end_date}"
    )

    # Get provider and credentials
    snaptrade_item = snaptrade_account.snaptrade_item
    provider = snaptrade_item.snaptrade_provider
    credentials = snaptrade_item.snaptrade_credentials

    unless provider && credentials
      Rails.logger.error("SnaptradeActivitiesFetchJob - No provider/credentials for account #{snaptrade_account.id}")
      return
    end

    # Fetch activities from API
    activities_data = fetch_activities(snaptrade_account, provider, credentials, start_date, end_date)

    if activities_data.any?
      Rails.logger.info(
        "SnaptradeActivitiesFetchJob - Got #{activities_data.size} activities for account #{snaptrade_account.id}"
      )

      # Merge with existing and save
      existing = snaptrade_account.raw_activities_payload || []
      merged = merge_activities(existing, activities_data)
      snaptrade_account.upsert_activities_snapshot!(merged)

      # Process the activities into trades/transactions
      process_activities(snaptrade_account)
    elsif retry_count < MAX_RETRIES
      # No activities yet, reschedule with delay
      Rails.logger.info(
        "SnaptradeActivitiesFetchJob - No activities yet for account #{snaptrade_account.id}, " \
        "rescheduling (#{retry_count + 1}/#{MAX_RETRIES})"
      )

      self.class.set(wait: RETRY_DELAY).perform_later(
        snaptrade_account,
        start_date: start_date,
        end_date: end_date,
        retry_count: retry_count + 1
      )
    else
      Rails.logger.warn(
        "SnaptradeActivitiesFetchJob - Max retries reached for account #{snaptrade_account.id}, " \
        "no activities fetched. This may be normal for new/empty accounts."
      )
    end
  rescue Provider::Snaptrade::AuthenticationError => e
    Rails.logger.error("SnaptradeActivitiesFetchJob - Auth error for account #{snaptrade_account.id}: #{e.message}")
    snaptrade_account.snaptrade_item.update!(status: :requires_update)
  rescue => e
    Rails.logger.error("SnaptradeActivitiesFetchJob - Error for account #{snaptrade_account.id}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n")) if e.backtrace
  end

  private

    def fetch_activities(snaptrade_account, provider, credentials, start_date, end_date)
      response = provider.get_account_activities(
        user_id: credentials[:user_id],
        user_secret: credentials[:user_secret],
        account_id: snaptrade_account.snaptrade_account_id,
        start_date: start_date,
        end_date: end_date
      )

      # Handle paginated response
      activities = if response.respond_to?(:data)
        response.data || []
      elsif response.is_a?(Array)
        response
      else
        []
      end

      # Convert SDK objects to hashes
      activities.map { |a| sdk_object_to_hash(a) }
    end

    def sdk_object_to_hash(obj)
      return obj if obj.is_a?(Hash)

      if obj.respond_to?(:to_json)
        JSON.parse(obj.to_json)
      elsif obj.respond_to?(:to_h)
        obj.to_h
      else
        obj
      end
    rescue JSON::ParserError, TypeError
      obj.respond_to?(:to_h) ? obj.to_h : {}
    end

    # Merge activities, deduplicating by ID
    # Fallback key includes symbol to distinguish activities with same date/type/amount
    def merge_activities(existing, new_activities)
      by_id = {}

      existing.each do |activity|
        a = activity.with_indifferent_access
        key = a[:id] || activity_fallback_key(a)
        by_id[key] = activity
      end

      new_activities.each do |activity|
        a = activity.with_indifferent_access
        key = a[:id] || activity_fallback_key(a)
        by_id[key] = activity # Newer data wins
      end

      by_id.values
    end

    def activity_fallback_key(activity)
      symbol = activity.dig(:symbol, :symbol) || activity.dig("symbol", "symbol")
      [ activity[:settlement_date], activity[:type], activity[:amount], symbol ]
    end

    def process_activities(snaptrade_account)
      account = snaptrade_account.current_account
      return unless account.present?

      processor = SnaptradeAccount::ActivitiesProcessor.new(snaptrade_account)
      processor.process

      # Clear the pending flag since activities have been processed
      snaptrade_account.update!(activities_fetch_pending: false)

      # Trigger UI refresh so new entries appear in the activity feed
      # This is critical for fresh account connections where activities are fetched
      # asynchronously after the main sync completes
      account.broadcast_sync_complete

      # Also broadcast for the snaptrade_item to update its status (spinner → done)
      snaptrade_account.snaptrade_item.broadcast_sync_complete

      Rails.logger.info(
        "SnaptradeActivitiesFetchJob - Processed and broadcast activities for account #{snaptrade_account.id}"
      )
    rescue => e
      Rails.logger.error(
        "SnaptradeActivitiesFetchJob - Failed to process activities for account #{snaptrade_account.id}: #{e.message}"
      )
    end
end
