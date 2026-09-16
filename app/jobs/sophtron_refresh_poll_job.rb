class SophtronRefreshPollJob < ApplicationJob
  queue_as :high_priority

  POLL_INTERVAL = 4.seconds
  MAX_ATTEMPTS = 60

  def perform(sophtron_account, job_id:, attempts_remaining: MAX_ATTEMPTS, sync: nil)
    Provider::AccountData::LegacyWriterFence.with_item(sophtron_account.sophtron_item, operation: :sync) do |item|
      current_account = scoped_account!(item, sophtron_account)
      current_sync = scoped_sync!(item, sync)
      poll!(item, current_account, job_id: job_id, attempts_remaining: attempts_remaining, sync: current_sync)
    end
  end

  private

    # Admission encloses client construction, HTTP, error handling and scheduling.
    # A denied old job must not clear flags on a source now owned by the new runtime.
    def poll!(sophtron_item, sophtron_account, job_id:, attempts_remaining:, sync:)
      provider = sophtron_item.sophtron_provider
      raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

      job = Provider::Sophtron.response_data!(provider.get_job_information(job_id))
      scoped_sync!(sophtron_item, sync)
      sophtron_account = scoped_account!(sophtron_item, sophtron_account)
      sophtron_item.upsert_job_snapshot!(job)

      if Provider::Sophtron.job_requires_input?(job)
        mark_requires_update!(sophtron_item, job_id)
      elsif Provider::Sophtron.job_failed?(job)
        sophtron_item.update!(last_connection_error: "Sophtron refresh failed")
      elsif Provider::Sophtron.job_success?(job) || Provider::Sophtron.job_completed?(job)
        import_transactions!(sophtron_item, sophtron_account, sync)
      elsif attempts_remaining.to_i > 1
        self.class.set(wait: POLL_INTERVAL).perform_later(
          sophtron_account,
          job_id: job_id,
          attempts_remaining: attempts_remaining.to_i - 1,
          sync: sync
        )
      else
        sophtron_item.update!(last_connection_error: "Sophtron refresh did not finish before the polling timeout")
      end
    rescue Provider::Sophtron::Error => error
      scoped_sync!(sophtron_item, sync)
      scoped_account!(sophtron_item, sophtron_account)
      handle_provider_error!(sophtron_item, error)
    end

    def scoped_account!(item, account)
      Provider::AccountData::LegacyWriterFence.scoped_accounts!(item, [ account ]).sole
    end

    def scoped_sync!(item, sync)
      # The item sync can finish before its delayed refresh, so completed is
      # intentionally valid. A cancelled ancestor still invalidates queued work.
      Provider::AccountData::LegacyWriterFence.scoped_sync!(item, sync, allow_completed: true)
    end

    def import_transactions!(sophtron_item, sophtron_account, sync)
      result = SophtronItem::Importer.new(sophtron_item, sync: sync)
                                    .import_transactions_after_refresh(sophtron_account)

      unless result[:success]
        attributes = { last_connection_error: result[:error] }
        attributes[:status] = :requires_update if result[:requires_update]
        sophtron_item.update!(attributes)
        return
      end

      scoped_sync!(sophtron_item, sync)
      sophtron_account = scoped_account!(sophtron_item, sophtron_account)
      SophtronAccount::Processor.new(sophtron_account, sync: sync, allow_completed: true).process

      account = sophtron_account.current_account
      return unless account

      sophtron_item.schedule_account_syncs(
        sophtron_accounts_scope: [ sophtron_account ], allow_completed: true,
        parent_sync: sync,
        window_start_date: sync&.window_start_date,
        window_end_date: sync&.window_end_date
      )
    end

    def mark_requires_update!(sophtron_item, job_id)
      sophtron_item.update!(
        status: :requires_update,
        current_job_id: job_id,
        last_connection_error: "Sophtron refresh requires MFA"
      )
    end

    def handle_provider_error!(sophtron_item, error)
      requires_update = error.error_type.in?([ :unauthorized, :access_forbidden ])
      attributes = { last_connection_error: error.message }
      attributes[:status] = :requires_update if requires_update
      sophtron_item.update!(attributes)
      DebugLogEntry.capture(category: "provider_sync_error", level: "error",
        message: "Sophtron refresh request failed", source: self.class.name,
        provider_key: "sophtron", family: sophtron_item.family,
        metadata: { item_id: sophtron_item.id, error_class: error.class.name })
    end
end
