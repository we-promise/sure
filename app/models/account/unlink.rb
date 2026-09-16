# Disconnect all current sources while retaining the financial account and its
# history. Connection deletion and credential revocation are separate operations.
class Account::Unlink
  class NotAuthorized < StandardError; end
  class CleanupFailed < StandardError; end

  def initialize(account:, user:)
    @account, @user = account, user
    @provider_types = []
  end

  def call
    Access.with_account(@account) do |current, disposition|
      authorize!(current)
      links = current.account_providers.order(:id).to_a
      @provider_types = links.map { |link| link.provider_key || link.provider_type }.compact.uniq.sort
      next false if links.empty? && current.plaid_account_id.nil? && current.simplefin_account_id.nil?

      # Lock every referring holding, including malformed cross-account rows,
      # before checking ownership. Neither a stale reference nor a failed
      # tracking-row callback may leave a partially unlinked account behind.
      link_ids = links.map(&:id)
      policies = Account::SourcePolicy.where(account_id: current.id, family_id: current.family_id, account_provider_id: link_ids)
        .order(:id).lock("FOR UPDATE NOWAIT").to_a
      policy_ids = policies.map(&:id)
      legacy_policy_ids = policies.reject { |policy| disposition.native_link_ids.include?(policy.account_provider_id) }.map(&:id)
      # Older commands can hide a secondary policy inside their encrypted
      # capture. Unknown routing cannot authorize detaching its possible owner.
      if legacy_policy_ids.any?
        Ingestion::HistoricalBalances::SourceBinding.assert_complete_for!(family_id: current.family_id)
        retained = IngestionBatch.where(family_id: current.family_id, source_policy_version: legacy_policy_ids)
          .or(IngestionBatch.where(family_id: current.family_id, origin_kind: "provider",
            stream: Ingestion::HistoricalBalances::SourceBinding::STREAMS)
            .where("source_binding->>'balance_policy_version' IN (?) OR source_binding->>'anchor_policy_version' IN (?)", legacy_policy_ids, legacy_policy_ids))
        if retained.exists?
          raise Provider::AccountData::LegacyWriterFence::OwnershipChanged, "Source selection has retained ingestion evidence"
        end
      end
      policies.each do |policy|
        if policy.source_binding.blank?
          raise Provider::AccountData::LegacyWriterFence::OwnershipChanged, "Source selection has no captured original owner"
        end
        Account::SourcePolicy::Binding.verify_live!(policy: policy)
      end
      holdings = Holding.where(account_provider_id: link_ids).order(:id).lock("FOR UPDATE NOWAIT").pluck(:id, :account_id)
      unless holdings.all? { |_id, account_id| account_id == current.id }
        raise Provider::AccountData::LegacyWriterFence::OwnershipChanged, "Provider holdings belong to another financial account"
      end
      cleanup = links.filter_map do |link|
        next if disposition.native_link_ids.include?(link.id)
        klass = case link.provider_type
        when "CoinstatsAccount" then CoinstatsAccount
        when "OnchainWalletAccount" then OnchainWalletAccount
        end
        [ klass, link.provider_id ] if klass
      end
      direct_simplefin = current.simplefin_account
      Account::SourcePolicy.where(id: policy_ids, active: true).update_all(active: false, updated_at: Time.current)
      # These are live routing pointers, not the sealed inputs they reference.
      # Future manual calculations must not inherit a disconnected provider's
      # historical handoff. Existing queued calculations keep their own proof
      # and will fail their original source-policy check if they resume later.
      Account::SyncSource.where(account_id: current.id, family_id: current.family_id)
        .order(:id).lock("FOR UPDATE NOWAIT").each(&:destroy!)
      current.holdings.where(account_provider_id: link_ids).update_all(account_provider_id: nil)
      links.each do |link|
        if disposition.native_link_ids.include?(link.id)
          # Native unlink deliberately retains copied tracking rows/mappings.
          # The only legacy destroy callbacks remove CoinStats/Onchain rows;
          # holdings and source policies have already been handled explicitly.
          link.delete
        else
          link.destroy!
        end
      end
      if cleanup.any? { |klass, id| klass.exists?(id) }
        raise CleanupFailed, "Provider tracking cleanup did not complete"
      end

      if current.owner_id.nil?
        # Saving an ownerless account assigns a default owner. These two source
        # links are already admitted and locked; clearing them must preserve
        # existing ownership and avoid locking an unrelated default owner.
        unless current.update_columns(plaid_account_id: nil, simplefin_account_id: nil, updated_at: Time.current)
          raise CleanupFailed, "Direct source links could not be cleared"
        end
      else
        current.update!(plaid_account_id: nil, simplefin_account_id: nil)
      end
      if direct_simplefin && !disposition.preserved_legacy_sources.include?([ "SimplefinAccount", direct_simplefin.id ])
        direct_simplefin.destroy!
      end
      true
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  private
    def authorize!(account)
      # Account's ownership validation locks its owner again on update. Acquire
      # actor and owner together now so shared-account unlink cannot wait in the
      # opposite order to an ownership transfer or user purge.
      ids = [ @user&.id, account.owner_id ].compact.uniq.sort
      users = User.where(id: ids).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
      user, owner = users[@user&.id], users[account.owner_id]
      owner_valid = account.owner_id.nil? || (owner && owner.family_id == account.family_id)
      unless user&.active? && user.family_id == account.family_id && owner_valid
        raise NotAuthorized, "Account management permission is required"
      end

      AccountShare.where(account_id: account.id, user_id: user.id).order(:id).lock("FOR UPDATE NOWAIT").load
      unless user.accessible_accounts.exists?(account.id) && account.permission_for(user).in?([ :owner, :full_control ])
        raise NotAuthorized, "Account management permission is required"
      end
    end

    def capture_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Account provider unlink failed",
        source: self.class.name, family: @account.family, account: @account,
        metadata: { account_id: @account.id, provider_types: @provider_types, error_class: error.class.name })
    rescue StandardError
      # Diagnostics cannot replace the original refusal or cleanup failure.
      nil
    end
end
