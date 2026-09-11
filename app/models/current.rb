class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session
  attribute :latest_sync_by_syncable, :latest_completed_sync_by_syncable, :syncing_by_syncable

  delegate :family, to: :user, allow_nil: true

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
    return family&.accounts unless user
    user.accessible_accounts
  end

  def finance_accounts
    return family&.accounts unless user
    user.finance_accounts
  end

  def accessible_entries
    return family&.entries unless user
    family.entries.joins(:account).merge(Account.accessible_by(user))
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
