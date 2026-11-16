# frozen_string_literal: true

class FamilyPolicy < ApplicationPolicy
  def destroy?
    user&.super_admin?
  end
end
