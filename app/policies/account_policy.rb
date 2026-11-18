# frozen_string_literal: true

class AccountPolicy < ApplicationPolicy
  def show?
    record.shared_with?(user)
  end

  def create?
    user.member? || user.admin?
  end

  # Full write tier: owner and full_control.
  def update?
    record.permission_for(user).in?([ :owner, :full_control ])
  end

  # Annotate tier (categorize, tag, add notes/merchant): the owner plus every
  # share tier in AccountShare::ANNOTATE_PERMISSIONS.
  def annotate?
    permission = record.permission_for(user)
    permission == :owner || permission.to_s.in?(AccountShare::ANNOTATE_PERMISSIONS)
  end

  # Maps the level names used by controllers (:write, :annotate, :owner) onto
  # the predicates above, so controller concerns share one mapping.
  def permits?(level)
    case level
    when :write    then update?
    when :annotate then annotate?
    when :owner    then record.owned_by?(user)
    else false
    end
  end

  # Only the owner can delete the account itself.
  # full_control users can delete transactions but not the account.
  def destroy?
    record.owned_by?(user)
  end

  def manage_sharing?
    record.owned_by?(user)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.accessible_by(user)
    end
  end
end
