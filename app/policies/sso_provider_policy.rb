# frozen_string_literal: true

class SsoProviderPolicy < ApplicationPolicy
  # Only super admins can manage SSO providers (instance-wide auth config)
  def index?
    user&.super_admin?
  end

  def show?
    user&.super_admin?
  end

  def create?
    user&.super_admin?
  end

  def new?
    create?
  end

  def update?
    user&.super_admin?
  end

  def edit?
    update?
  end

  def destroy?
    user&.super_admin?
  end

  def toggle?
    update?
  end

  def test_connection?
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
