module StashawayItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    stashaway_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: "StashawayAccount", provider_id: provider_account.id).to_a
      link_ids = links.map(&:id)
      result = {
        provider_account_id: provider_account.id,
        name: provider_account.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          links.each(&:destroy!)
          # Both describe the account that was linked; the next link sets its own.
          provider_account.update!(import_start_date: nil, import_base: nil)
        end
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "StashawayItem Unlinker: failed to fully unlink provider account ##{provider_account.id} " \
                   "(links=#{link_ids.inspect}): #{e.class} - #{e.message}",
          source: "stashaway",
          family: family,
          provider_key: "stashaway"
        )
        result[:error] = e.message
      end
    end

    results
  end
end
