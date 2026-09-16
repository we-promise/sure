# frozen_string_literal: true

module SophtronItem::Unlinking
  extend ActiveSupport::Concern

  # Idempotently removes all connections between this Sophtron item and local accounts.
  #
  # This method:
  # - Finds all AccountProvider links for each SophtronAccount
  # - Detaches any Holdings associated with those links
  # - Destroys the AccountProvider links
  # - Returns detailed results for observability
  #
  # This mirrors the SimplefinItem::Unlinking behavior.
  #
  # @param dry_run [Boolean] If true, only report what would be unlinked without making changes
  # @return [Array<Hash>] Results for each account with keys:
  #   - :sfa_id [Integer] The SophtronAccount ID
  #   - :name [String] The account name
  #   - :provider_link_ids [Array<Integer>] IDs of AccountProvider links found
  # @example
  #   item.unlink_all!(dry_run: true)  # Preview what would be unlinked
  #   item.unlink_all!                 # Actually unlink all accounts
  def unlink_all!(dry_run: false)
    SophtronItem::LegacyAccess.with_item(self, operation: :lifecycle) do |item|
      item.sophtron_accounts.order(:id).map do |source|
        item.unlink_account!(source, dry_run: dry_run)
      end
    end
  end

  def unlink_account!(source, dry_run: false)
    SophtronItem::LegacyAccess.with_item(self, operation: :lifecycle) do |item|
      current = Provider::AccountData::LegacyWriterFence.scoped_accounts!(item, [ source ]).sole
      item.send(:unlink_admitted_account!, current, dry_run: dry_run)
    end
  end

  private
    def unlink_admitted_account!(source, dry_run:)
      fence = Provider::AccountData::LegacyWriterFence
      result = { sfa_id: source.id, name: source.name, provider_link_ids: [] }
      links = AccountProvider.where(provider_type: "SophtronAccount", provider_id: source.id)
      planned_links = AccountProvider.uncached { links.order(:id).pluck(:id, :account_id) }
      result[:provider_link_ids] = planned_links.map(&:first)

      Account.transaction do
        # Fix the lock set before acquiring Account. A relink requires a new
        # operation, never extending the Account lock set after locking source.
        account_ids = planned_links.map(&:last).uniq.sort
        accounts = family.accounts.where(id: account_ids).order(:id).lock.to_a
        unless accounts.map(&:id).sort == account_ids
          raise fence::OwnershipChanged, "Sophtron unlink contains another family's account"
        end
        current = sophtron_accounts.lock.find(source.id)
        fence.scoped_accounts!(self, [ current ])
        current_links = links.order(:id).lock.to_a
        unless current_links.map { |link| [ link.id, link.account_id ] } == planned_links
          raise fence::OwnershipChanged, "Sophtron links changed during unlink"
        end
        result[:name] = current.name
        current_links.each do |link|
          if Holding.where(account_provider_id: link.id).where.not(account_id: link.account_id).exists?
            raise fence::OwnershipChanged, "Sophtron holding belongs to another financial account"
          end
        end
        unless dry_run
          Holding.where(account_provider_id: result[:provider_link_ids]).update_all(account_provider_id: nil)
          current_links.each(&:destroy!)
        end
      end
      result
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => error
      begin
        DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
          message: "Sophtron account could not be unlinked", source: self.class.name,
          provider_key: "sophtron", family: family,
          metadata: { item_id: id, sophtron_account_id: source.id, error_class: error.class.name })
      rescue StandardError
        # Diagnostics must not replace the failed operation's result.
      end
      result.merge(error: error.class.name)
    end
end
