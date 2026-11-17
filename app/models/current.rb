class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session
  attribute :latest_sync_by_syncable, :latest_completed_sync_by_syncable, :syncing_by_syncable

  delegate :family, to: :user, allow_nil: true

  resets { @accessible_accounts = @finance_accounts = nil }

  def user
    impersonated_user || session&.user
  end

  def impersonated_user
    session&.active_impersonator_session&.impersonated
  end

  def true_user
    session&.user
  end

  def accessible_accounts
    @accessible_accounts ||= (user ? user.accessible_accounts : family&.accounts)&.load
  end

  def finance_accounts
    @finance_accounts ||= (user ? user.finance_accounts : family&.accounts)&.load
  end

  def accessible_entries
    return family&.entries unless user
    family.entries.joins(:account).merge(Account.accessible_by(user))
  end

  # Entries the user may annotate (notes, category, merchant, tags): owned
  # accounts and shares with full_control or read_write, not read_only.
  def annotatable_entries
    return family&.entries unless user
    family.entries.joins(:account).merge(Account.annotatable_by(user))
  end

  # Used for invalidating caches whose results depend on the current user's
  # account-share access (e.g. the transactions index's uncategorized count
  # and projected recurring list, which are scoped to accessible accounts).
  # Changes whenever an AccountShare granting/revoking the user's access is
  # created, updated, or destroyed.
  def account_share_version
    return "0-" unless user
    shares = AccountShare.where(user: user)
    "#{shares.count}-#{shares.maximum(:updated_at)&.to_f}"
  end
end
