class Family::Syncer
  attr_reader :family

  # Registry of item association names that participate in family sync.
  # Each model must:
  #   1. Include Syncable
  #   2. Define a `syncable` scope (items ready for auto-sync)
  #
  # To add a new provider: add its association name here.
  # The model handles its own "ready to sync" logic via the syncable scope.
  SYNCABLE_ITEM_ASSOCIATIONS = %i[
    plaid_items
    simplefin_items
    lunchflow_items
    enable_banking_items
    indexa_capital_items
    coinbase_items
    coinstats_items
    mercury_items
    snaptrade_items
  ].freeze

  def initialize(family)
    @family = family
  end

  def perform_sync(sync)
    # We don't rely on this value to guard the app, but keep it eventually consistent
    family.sync_trial_status!

    # Schedule child syncs
    child_syncables.each do |syncable|
      syncable.sync_later(parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
    end
  end

  def perform_post_sync
    family.auto_match_transfers!

    Rails.logger.info("Applying rules for family #{family.id}")
    family.rules.where(active: true).each do |rule|
      rule.apply_later
    end
  end

  private

    # Collects all syncable items from registered providers + manual accounts.
    # Each provider model defines its own `syncable` scope that encapsulates
    # the "ready to sync" business logic (active, configured, etc.)
    def child_syncables
      provider_items = SYNCABLE_ITEM_ASSOCIATIONS.flat_map do |association|
        family.public_send(association).syncable
      end

      provider_items + family.accounts.manual
    end
end
