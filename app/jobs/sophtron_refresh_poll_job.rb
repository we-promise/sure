class SophtronRefreshPollJob < ApplicationJob
  queue_as :high_priority

  POLL_INTERVAL = 4.seconds
  MAX_ATTEMPTS = 60

  def perform(sophtron_account, job_id:, attempts_remaining: MAX_ATTEMPTS, sync: nil)
    sophtron_item = sophtron_account.sophtron_item
    provider = sophtron_item.sophtron_provider
    raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

    job = Provider::Sophtron.response_data!(provider.get_job_information(job_id))
    sophtron_item.upsert_job_snapshot!(job)

    if Provider::Sophtron.job_requires_input?(job)
      mark_requires_update!(sophtron_item, job_id)
    elsif Provider::Sophtron.job_failed?(job)
      sophtron_item.update!(last_connection_error: "Sophtron refresh failed")
    elsif Provider::Sophtron.job_success?(job) || Provider::Sophtron.job_completed?(job)
      import_transactions!(sophtron_account, provider, sync)
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
  rescue Provider::Sophtron::Error => e
    handle_provider_error!(sophtron_account.sophtron_item, e)
  end

  private

    def import_transactions!(sophtron_account, provider, sync)
      sophtron_item = sophtron_account.sophtron_item
      result = SophtronItem::Importer.new(sophtron_item, sophtron_provider: provider, sync: sync)
                                    .import_transactions_after_refresh(sophtron_account)

      unless result[:success]
        attributes = { last_connection_error: result[:error] }
        attributes[:status] = :requires_update if result[:requires_update]
        sophtron_item.update!(attributes)
        return
      end

      SophtronAccount::Processor.new(sophtron_account.reload).process

      account = sophtron_account.current_account
      return unless account

      account.sync_later(
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
      Rails.logger.error "SophtronRefreshPollJob - Sophtron API error for item #{sophtron_item.id}: #{error.message}"
    end
end
