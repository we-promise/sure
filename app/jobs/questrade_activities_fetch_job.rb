# frozen_string_literal: true

class QuestradeActivitiesFetchJob < ApplicationJob
  include QuestradeAccount::DataHelpers

  queue_as :default

  MAX_RETRIES = 6
  RETRY_INTERVAL = 10.seconds

  sidekiq_options lock: :until_executed,
                  lock_args_method: ->(args) { args.first },
                  on_conflict: :log

  def perform(questrade_account, start_date: nil, retry_count: 0)
    @questrade_account = questrade_account
    @start_date = start_date || 3.years.ago.to_date
    @retry_count = retry_count

    return clear_pending_flag unless valid_for_fetch?

    fetch_and_process_activities
  rescue => e
    Rails.logger.error("QuestradeActivitiesFetchJob error: #{e.class} - #{e.message}")
    clear_pending_flag
    raise
  end

  private

    def valid_for_fetch?
      return false unless @questrade_account
      return false unless @questrade_account.questrade_item
      return false unless @questrade_account.current_account
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
        @questrade_account.upsert_activities_snapshot!(merged)
        @questrade_account.update!(last_activities_sync: Time.current)

        QuestradeAccount::ActivitiesProcessor.new(@questrade_account).process
      end

      clear_pending_flag
      broadcast_updates
    end

    def fetch_activities
      provider = @questrade_account.questrade_item.questrade_provider
      return [] unless provider

      response = provider.get_activities(
        account_id: @questrade_account.questrade_account_id,
        start_date: @start_date,
        end_date: Date.current
      )
      Array(response.is_a?(Hash) ? response[:activities] : response)
    rescue Provider::Questrade::AuthenticationError
      # Re-raise auth errors - they need immediate attention
      raise
    rescue => e
      # Transient errors trigger retry via blank response
      Rails.logger.error("QuestradeActivitiesFetchJob - API error: #{e.message}")
      []
    end

    def existing_activities
      @questrade_account.raw_activities_payload || []
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
      # Questrade activities have no id; key on the immutable fields (same basis
      # as QuestradeItem::Importer#activity_key) to dedup across syncs.
      [ activity[:transactionDate], activity[:action], activity[:symbolId],
        activity[:netAmount], activity[:description] ].join("-")
    end

    def schedule_retry
      Rails.logger.info(
        "QuestradeActivitiesFetchJob - No activities found, scheduling retry " \
        "#{@retry_count + 1}/#{MAX_RETRIES} in #{RETRY_INTERVAL.to_i}s"
      )

      self.class.set(wait: RETRY_INTERVAL).perform_later(
        @questrade_account,
        start_date: @start_date,
        retry_count: @retry_count + 1
      )
    end

    def clear_pending_flag
      @questrade_account.update!(activities_fetch_pending: false)
    end

    def broadcast_updates
      @questrade_account.current_account&.broadcast_sync_complete
      @questrade_account.questrade_item&.broadcast_replace_to(
        @questrade_account.questrade_item.family,
        target: "questrade_item_#{@questrade_account.questrade_item.id}",
        partial: "questrade_items/questrade_item"
      )
    rescue => e
      Rails.logger.warn("QuestradeActivitiesFetchJob - Broadcast failed: #{e.message}")
    end
end
