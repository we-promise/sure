# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  # Only super_admins can manage user roles
  def index?
    user&.super_admin?
  end

  def update?
    return false unless user&.super_admin?
    # Prevent users from changing their own role (must be done by another super_admin)
    user.id != record.id
  end

  def destroy?
    # Self-deletion is blocked in the controller so it can redirect with a
    # friendly message rather than raising an authorization error.
    user&.super_admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.super_admin?
        scope.all
      else
        scope.none
      end
    end
  end
end
