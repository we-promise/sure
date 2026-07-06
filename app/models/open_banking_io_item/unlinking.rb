module OpenBankingIoItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    open_banking_io_accounts.find_each do |provider_account|
      links = AccountProvider.joins(:account)
                             .where(provider: provider_account, accounts: { family_id: family_id })
                             .to_a
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
          links.each do |link|
            Holding.where(account_id: link.account_id, account_provider_id: link.id).update_all(account_provider_id: nil)
            link.destroy!
          end
        end
      rescue StandardError => e
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "Failed to fully unlink provider account",
          source: self.class.name,
          provider_key: "open_banking_io",
          family: family,
          account_provider: links.first,
          metadata: {
            open_banking_io_item_id: id,
            open_banking_io_account_id: provider_account.id,
            link_ids: link_ids,
            error_class: e.class.name,
            error_message: e.message
          }
        )
        result[:error] = e.message
      end
    end

    results
  end
end
