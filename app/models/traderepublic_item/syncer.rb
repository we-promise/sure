class TraderepublicItem::Syncer
  attr_reader :traderepublic_item

  def initialize(traderepublic_item)
    @traderepublic_item = traderepublic_item
  end

  def perform_sync(sync)
    # Phase 1: Check session status
    unless traderepublic_item.session_configured?
      Rails.logger.error "TraderepublicItem::Syncer - No session configured for item #{traderepublic_item.id}"
      traderepublic_item.update!(status: :requires_update)
      sync.update!(status_text: "Login required") if sync.respond_to?(:status_text)
      return
    end

    # Phase 2: Import data from TradeRepublic API
    sync.update!(status_text: "Importing portfolio from Trade Republic...") if sync.respond_to?(:status_text)
    
    begin
      traderepublic_item.import_latest_traderepublic_data(sync: sync)
    rescue TraderepublicError => e
      Rails.logger.error "TraderepublicItem::Syncer - Import failed: #{e.message}"
      
      # Mark as requires_update if authentication error
      if [ :unauthorized, :auth_failed ].include?(e.error_code)
        traderepublic_item.update!(status: :requires_update)
        sync.update!(status_text: "Authentication failed - login required") if sync.respond_to?(:status_text)
      else
        sync.update!(status_text: "Import failed: #{e.message}") if sync.respond_to?(:status_text)
      end
      return
    end

    # Phase 3: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = traderepublic_item.traderepublic_accounts.count
    linked_accounts = traderepublic_item.traderepublic_accounts.joins(:linked_account).merge(Account.visible)
    unlinked_accounts = traderepublic_item.traderepublic_accounts.includes(:linked_account).where(accounts: { id: nil })

    # Store sync statistics for display
    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      traderepublic_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      traderepublic_item.update!(pending_account_setup: false)
    end

    # Phase 4: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      Rails.logger.info "TraderepublicItem::Syncer - Processing #{linked_accounts.count} linked accounts (appel Processor sur chaque compte)"
      traderepublic_item.process_accounts
      Rails.logger.info "TraderepublicItem::Syncer - Finished processing accounts"

      # Phase 5: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      traderepublic_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    else
      Rails.logger.info "TraderepublicItem::Syncer - No linked accounts to process (Importer utilisé uniquement à l'import initial)"
    end

    # Store sync statistics in the sync record for status display
    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: sync_stats)
    end

    # Recalculate holdings for all linked accounts
    linked_accounts.each do |traderepublic_account|
      account = traderepublic_account.linked_account
      next unless account
      Rails.logger.info "TraderepublicItem::Syncer - Recalculating holdings for account #{account.id}"
      Holding::Materializer.new(account, strategy: :forward).materialize_holdings
    end
  end

  def perform_post_sync
    # no-op for now
  end
end
