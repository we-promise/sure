# frozen_string_literal: true

# Shared logic for provider items scheduling per-account balance syncs after import.
module Account::SchedulesBalanceSyncs
  extend ActiveSupport::Concern

  # @param accounts [Enumerable<Account>, nil] Defaults to {#balance_sync_accounts}
  # @return [Array<Hash>, nil] Result rows when +report_results+ is true; otherwise nil
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil, import_window_start_date: nil, accounts: nil, report_results: schedule_account_syncs_report_results?)
    schedule_account_syncs_for(
      accounts || balance_sync_accounts,
      parent_sync: parent_sync,
      window_start_date: window_start_date,
      window_end_date: window_end_date,
      import_window_start_date: import_window_start_date,
      report_results: report_results
    )
  end

  def schedule_account_syncs_for(accounts, parent_sync: nil, window_start_date: nil, window_end_date: nil, import_window_start_date: nil, report_results: schedule_account_syncs_report_results?)
    return [] if report_results && accounts.blank?

    end_date = window_end_date || parent_sync&.window_end_date
    last_synced = balance_sync_last_synced_at

    iterator = report_results ? :schedule_with_results : :schedule_each
    send(iterator, accounts, parent_sync:, window_start_date:, end_date:, import_window_start_date:, last_synced:)
  end

  private

    def schedule_account_syncs_report_results?
      false
    end

    def balance_sync_accounts
      accts = accounts
      accts.respond_to?(:visible) ? accts.visible : accts
    end

    def balance_sync_last_synced_at
      last_synced_at if respond_to?(:last_synced_at)
    end

    def schedule_each(accounts, parent_sync:, window_start_date:, end_date:, import_window_start_date:, last_synced:)
      accounts.each do |account|
        schedule_balance_sync_for_account(
          account,
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: end_date,
          import_window_start_date: import_window_start_date,
          last_synced_at: last_synced
        )
      end
      nil
    end

    def schedule_with_results(accounts, parent_sync:, window_start_date:, end_date:, import_window_start_date:, last_synced:)
      results = []
      accounts.each do |account|
        schedule_balance_sync_for_account(
          account,
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: end_date,
          import_window_start_date: import_window_start_date,
          last_synced_at: last_synced
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "#{self.class.name} #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
      results
    end

    def schedule_balance_sync_for_account(account, parent_sync:, window_start_date:, window_end_date:, import_window_start_date:, last_synced_at:)
      effective_window = Account::BalanceSyncWindow.for_account(
        account,
        parent_sync: parent_sync,
        parent_window_start_date: window_start_date || parent_sync&.window_start_date,
        import_window_start_date: import_window_start_date,
        last_synced_at: last_synced_at
      )

      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: effective_window,
        window_end_date: window_end_date
      )
    end
end
