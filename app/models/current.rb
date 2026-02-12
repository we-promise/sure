class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session

  def user
    impersonated_user || session&.user
  end

  def family
    session&.family || user&.family
  end

  def membership
    return nil unless user && family
    user.membership_for(family)
  end

  def admin?
    user&.super_admin? || membership&.admin?
  end

  def impersonated_user
    session&.active_impersonator_session&.impersonated
  end

  def true_user
    session&.user
  end
end
