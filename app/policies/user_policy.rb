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
