# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  # Only super_admins can manage user roles
  def index?
    user&.super_admin?
  end

  def update?
    user&.super_admin?
  end

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
