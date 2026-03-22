class EnableBankingItem::Syncer
  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
  end

  def perform_sync(sync)
    # Check if session is valid before syncing
    unless enable_banking_item.session_valid?
      sync.update!(status_text: "Session expired - re-authorization required") if sync.respond_to?(:status_text)
      enable_banking_item.update!(status: :requires_update)
      raise StandardError.new("Enable Banking session has expired. Please re-authorize.")
    end

    # Phase 1: Import data from Enable Banking API
    sync.update!(status_text: "Importing accounts from Enable Banking...") if sync.respond_to?(:status_text)
    import_result = enable_banking_item.import_latest_enable_banking_data

    unless import_result[:success]
      error_msg = import_result[:error]
      if error_msg.blank? && (import_result[:accounts_failed].to_i > 0 || import_result[:transactions_failed].to_i > 0)
        parts = []
        parts << "#{import_result[:accounts_failed]} #{'account'.pluralize(import_result[:accounts_failed])} failed" if import_result[:accounts_failed].to_i > 0
        parts << "#{import_result[:transactions_failed]} #{'transaction'.pluralize(import_result[:transactions_failed])} failed" if import_result[:transactions_failed].to_i > 0
        error_msg = parts.join(", ")
      end
      raise StandardError.new(error_msg.presence || "Import failed")
    end

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = enable_banking_item.enable_banking_accounts.count

    linked_accounts = enable_banking_item.enable_banking_accounts.joins(:account_provider).joins(:account).merge(Account.visible)
    unlinked_accounts = enable_banking_item.enable_banking_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    if unlinked_accounts.any?
      enable_banking_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      enable_banking_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      enable_banking_item.process_accounts

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      enable_banking_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: sync_stats)
    end
  end

  def perform_post_sync
    # no-op
  end
end
