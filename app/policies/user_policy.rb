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

  # Permanent removal of a user from the instance. Super-admin only, and never
  # the acting user themselves (self-removal is blocked here and re-checked in
  # the controller so it surfaces a friendly message instead of a hard 403).
  def destroy?
    return false unless user&.super_admin?
    user.id != record.id
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
