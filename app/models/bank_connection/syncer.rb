class BankConnection::Syncer
  attr_reader :bank_connection

  def initialize(bank_connection)
    @bank_connection = bank_connection
  end

  def perform_sync(sync)
    bank_connection.import_latest_bank_data

    unlinked = bank_connection.bank_external_accounts.includes(:account).where(accounts: { id: nil })
    if unlinked.any?
      bank_connection.update!(pending_account_setup: true)
      return
    end

    bank_connection.process_accounts

    bank_connection.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
  end

  def perform_post_sync
    # no-op
  end
end

