module TradeRepublicItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    trade_republic_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: "TradeRepublicAccount", provider_id: provider_account.id).to_a
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
          Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
          links.each(&:destroy!)
        end
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "TradeRepublicItem Unlinker: failed to fully unlink provider account ##{provider_account.id} " \
                   "(links=#{link_ids.inspect}): #{e.class} - #{e.message}",
          source: "trade_republic",
          family: family,
          provider_key: "trade_republic"
        )
        result[:error] = e.message
      end
    end

    results
  end
end
