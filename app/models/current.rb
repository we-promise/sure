class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session

  def user
    impersonated_user || session&.user
  end

  def family
    session&.active_family || user&.active_family(session)
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
    current_family = family
    return current_family&.entries unless user
    return Entry.none if current_family.blank?

    current_family.entries.joins(:account).merge(Account.accessible_by(user))
  end
end
