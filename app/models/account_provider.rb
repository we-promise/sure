class AccountProvider < ApplicationRecord
  belongs_to :account
  belongs_to :provider, polymorphic: true, optional: true
  belongs_to :external_account, optional: true
  belongs_to :family, optional: true

  has_many :holdings, dependent: :nullify
  # Historical revisions retain the original link UUID. The database keeps a
  # live link only while a policy is active or lacks captured source ownership.
  has_many :source_policies, class_name: "Account::SourcePolicy"

  validates :account_id, uniqueness: { scope: :provider_type }, if: :provider_type?
  validates :provider_id, uniqueness: { scope: :provider_type }, if: :provider_type?
  validates :account_id, uniqueness: { scope: :provider_key }, if: :external_account_id?
  validates :external_account_id, uniqueness: true, allow_nil: true
  before_validation :assign_shared_identity
  validate :consistent_shared_link

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
    Provider::Factory.create_adapter(effective_provider, account: account)
  end

  def effective_provider
    if external_account
      control = external_account.provider_connection.provider_migration_control
      return external_account if control.nil? || control.native_owned?
    end
    provider
  end

  # Convenience method to get provider name
  # Delegates to the adapter for consistency, falls back to underscored provider_type
  def provider_name
    adapter&.provider_name || provider_key || provider_type&.underscore
  end

  private

    def assign_shared_identity
      return unless external_account
      self.family_id ||= account&.family_id
      self.provider_key ||= external_account.provider_key
    end

    def consistent_shared_link
      errors.add(:provider, "is required") unless provider || external_account
      return unless external_account
      unless account&.family_id == family_id && external_account.family_id == family_id &&
          external_account.provider_key == provider_key
        errors.add(:external_account, "must belong to the account family and provider")
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
