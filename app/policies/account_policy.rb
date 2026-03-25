# frozen_string_literal: true

class AccountPolicy < ApplicationPolicy
  def show?
    record.shared_with?(user)
  end

  def create?
    user.member? || user.admin?
  end

  def update?
    permission = record.permission_for(user)
    permission.in?([ :owner, :full_control ])
  end

  # For read_write users: categorize, tag, add notes/receipts on transactions
  def annotate?
    permission = record.permission_for(user)
    permission.in?([ :owner, :full_control, :read_write ])
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
