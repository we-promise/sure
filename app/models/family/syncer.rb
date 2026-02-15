class Family::Syncer
  attr_reader :family

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
    # Apply rules after all child syncs complete so newly imported transactions are included
    Rails.logger.info("Applying rules for family #{family.id}")
    family.rules.where(active: true).each do |rule|
      rule.apply_later
    end

    family.auto_match_transfers!
  end

  private
    def child_syncables
      family.plaid_items + family.simplefin_items.active + family.lunchflow_items.active + family.enable_banking_items.active + family.accounts.manual
    end
end
