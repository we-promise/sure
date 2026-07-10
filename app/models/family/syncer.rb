class Family::Syncer
  # Family-wide transfer matching runs after every sync, so it only needs to
  # consider recently-dated entries — older pairs were already examined by
  # previous runs. Without a bound the candidate query self-joins the family's
  # entire entries history (O(N^2) for large families) on every sync.
  # Account-level syncs still match across full history for their account.
  TRANSFER_MATCHING_LOOKBACK = 90.days

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
    family.auto_match_transfers!(since_date: TRANSFER_MATCHING_LOOKBACK.ago.to_date)

    Rails.logger.info("Applying rules for family #{family.id}")
    family.rules.where(active: true).each do |rule|
      rule.apply_later
    end
  end

  private

    # Collect all syncable provider items via reflection so new `*_items`
    # integrations participate in nightly family sync as soon as they include
    # Syncable and expose a `syncable` scope.
    def child_syncables
      provider_items = syncable_item_associations.flat_map do |association|
        family.public_send(association).syncable
      end

      provider_items + family.accounts.manual
    end

    def syncable_item_associations
      Family.reflect_on_all_associations(:has_many).filter_map do |association|
        next unless association.name.to_s.end_with?("_items")
        next unless association.klass.included_modules.include?(Syncable)

        association.name
      rescue NameError
        nil
      end
    end
end
