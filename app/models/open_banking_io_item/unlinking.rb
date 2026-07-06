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
        Rails.logger.warn(
          "OpenBankingIoItem Unlinker: failed to fully unlink provider account ##{provider_account.id} " \
          "(links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        result[:error] = e.message
      end
    end

    results
  end
end
