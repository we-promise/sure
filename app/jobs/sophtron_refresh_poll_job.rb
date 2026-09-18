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
    log_refresh_event(
      sophtron_account,
      message: "Sophtron refresh poll received job state",
      metadata: {
        sync_id: sync&.id,
        job_id: job_id,
        attempts_remaining: attempts_remaining,
        job_status: job.with_indifferent_access[:LastStatus] || job.with_indifferent_access[:last_status],
        job_step: job.with_indifferent_access[:LastStep] || job.with_indifferent_access[:last_step]
      }
    )

    if Provider::Sophtron.job_requires_input?(job)
      mark_requires_update!(sophtron_item, job_id)
      log_refresh_event(sophtron_account, level: "warn", message: "Sophtron refresh poll requires MFA", metadata: { sync_id: sync&.id, job_id: job_id })
    elsif Provider::Sophtron.job_failed?(job)
      sophtron_item.update!(last_connection_error: I18n.t("sophtron_items.errors.refresh_failed"))
      log_refresh_event(sophtron_account, level: "error", message: "Sophtron refresh poll failed", metadata: { sync_id: sync&.id, job_id: job_id })
    elsif Provider::Sophtron.job_success?(job) || Provider::Sophtron.job_completed?(job)
      import_transactions!(sophtron_account, provider, sync)
    elsif attempts_remaining.to_i > 1
      self.class.set(wait: POLL_INTERVAL).perform_later(
        sophtron_account,
        job_id: job_id,
        attempts_remaining: attempts_remaining.to_i - 1,
        sync: sync
      )
      log_refresh_event(sophtron_account, message: "Sophtron refresh poll re-enqueued", metadata: { sync_id: sync&.id, job_id: job_id, attempts_remaining: attempts_remaining.to_i - 1 })
    else
      sophtron_item.update!(last_connection_error: I18n.t("sophtron_items.errors.refresh_timeout"))
      log_refresh_event(sophtron_account, level: "error", message: "Sophtron refresh poll timed out", metadata: { sync_id: sync&.id, job_id: job_id })
    end
  rescue Provider::Sophtron::Error => e
    handle_provider_error!(sophtron_account.sophtron_item, e)
    log_refresh_event(sophtron_account, level: "error", message: "Sophtron refresh poll failed with provider error", metadata: { sync_id: sync&.id, job_id: job_id, error: e.message, error_type: e.error_type })
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
        log_refresh_event(sophtron_account, level: result[:requires_update] ? "warn" : "error", message: "Sophtron refresh import failed after polling", metadata: { sync_id: sync&.id, error: result[:error], requires_update: result[:requires_update] })
        return
      end

      log_refresh_event(sophtron_account, message: "Sophtron refresh import completed after polling", metadata: { sync_id: sync&.id, transactions_count: result[:transactions_count] })

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
        last_connection_error: I18n.t("sophtron_items.errors.refresh_requires_mfa")
      )
    end

    def handle_provider_error!(sophtron_item, error)
      requires_update = error.error_type.in?([ :unauthorized, :access_forbidden ])
      attributes = { last_connection_error: error.message }
      attributes[:status] = :requires_update if requires_update
      sophtron_item.update!(attributes)
      Rails.logger.error "SophtronRefreshPollJob - Sophtron API error for item #{sophtron_item.id}: #{error.message}"
    end

    def log_refresh_event(sophtron_account, message:, level: "info", metadata: {})
      sophtron_account.sophtron_item.debug_log_event(
        category: "sophtron_transaction_sync",
        level: level,
        message: message,
        source: self.class.name,
        account: sophtron_account.current_account,
        account_provider: sophtron_account.account_provider,
        metadata: {
          sophtron_account_id: sophtron_account.id,
          sophtron_account_external_id: sophtron_account.account_id
        }.merge(metadata)
      )
    end
end
