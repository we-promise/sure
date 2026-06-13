class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session
  attribute :accessible_accounts_cache, :finance_accounts_cache

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
    self.accessible_accounts_cache ||= user.accessible_accounts
  end

  def finance_accounts
    return family&.accounts unless user
    self.finance_accounts_cache ||= user.finance_accounts
  end

  def accessible_entries
    return family&.entries unless user
    family.entries.joins(:account).merge(Account.accessible_by(user))
  end
end
