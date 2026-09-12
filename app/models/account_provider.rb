class AccountProvider < ApplicationRecord
  belongs_to :account
  belongs_to :provider, polymorphic: true

  has_many :holdings, dependent: :nullify

  validates :account_id, uniqueness: { scope: :provider_type }
  validates :provider_id, uniqueness: { scope: :provider_type }

  validate :financekit_has_exclusive_writer, if: -> { new_record? || will_save_change_to_account_id? || will_save_change_to_provider_id? || will_save_change_to_provider_type? }

  # When unlinking a CoinStats account, also destroy the CoinstatsAccount record
  # so it doesn't remain orphaned and count as "needs setup".
  # Other providers may legitimately enter a "needs setup" state.
  after_destroy :destroy_coinstats_provider_account, if: :coinstats_provider?

  # An on-chain tracking row IS the link: unlike a bank connection there is
  # nothing to reconnect to and nothing worth keeping. Left behind by a generic
  # unlink it stops syncing, because the syncer only reads linked rows, while
  # its partial unique index still holds the (item, chain, address, asset) slot
  # — so linking that same asset again would collide with a row nothing shows.
  # The Sure account and its holdings are untouched and carry on as manual.
  after_destroy :destroy_onchain_provider_account, if: :onchain_provider?

  # Returns the provider adapter for this connection
  def adapter
    Provider::Factory.create_adapter(provider, account: account)
  end

  # Convenience method to get provider name
  # Delegates to the adapter for consistency, falls back to underscored provider_type
  def provider_name
    adapter&.provider_name || provider_type.underscore
  end

  private

    def financekit_has_exclusive_writer
      return unless account_id
      # Every provider link takes the same canonical-account lock. This closes
      # the race between FinanceKit mapping and another provider's setup flow.
      Account.where(id: account_id).lock.pick(:id)
      others = self.class.where(account_id: account_id).where.not(id: id)
      conflict = provider_type == "FinancekitAccount" ? others.exists? : others.where(provider_type: "FinancekitAccount").exists?
      errors.add(:account, "already has an exclusive FinanceKit publisher") if conflict
      if provider_type == "FinancekitAccount" && provider&.financekit_item&.family_id != account.family_id
        errors.add(:account, "must belong to the FinanceKit enrollment family")
      end
    end

    def coinstats_provider?
      provider_type == "CoinstatsAccount"
    end

    def destroy_coinstats_provider_account
      provider&.destroy
    end

    def onchain_provider?
      provider_type == "OnchainWalletAccount"
    end

    def destroy_onchain_provider_account
      # Skipped only when the row is the one destroying this link, through its
      # own dependent: :destroy — answering that by destroying the row again
      # would go round in circles. The account destroys this link by association
      # too, and there the row must follow: a guard reading nothing but
      # `destroyed_by_association` could not tell the two apart, and left the
      # row behind with no account to track.
      return if destroyed_by_association&.active_record == OnchainWalletAccount

      provider&.destroy
    end
end
