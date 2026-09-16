class SophtronInitialLoadJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 30

  def perform(sophtron_item, attempts_remaining: MAX_ATTEMPTS)
    Provider::AccountData::LegacyWriterFence.with_item(sophtron_item, operation: :sync) do |current|
      schedule_load(current, attempts_remaining: attempts_remaining)
    end
  end

  private

    def schedule_load(sophtron_item, attempts_remaining:)
      if sophtron_item.syncing?
        if attempts_remaining.positive?
          self.class.set(wait: RETRY_DELAY).perform_later(sophtron_item, attempts_remaining: attempts_remaining - 1)
        else
          DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
            message: "Sophtron initial load exhausted its wait attempts", source: self.class.name,
            provider_key: "sophtron", family: sophtron_item.family,
            metadata: { item_id: sophtron_item.id })
        end

        return
      end

      sophtron_item.sync_later
    end
end
