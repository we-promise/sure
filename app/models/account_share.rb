class AccountShare < ApplicationRecord
  belongs_to :account
  belongs_to :user

  PERMISSIONS = %w[full_control read_write read_only].freeze

  validates :permission, inclusion: { in: PERMISSIONS }
  validates :user_id, uniqueness: { scope: :account_id }
  validate :cannot_share_with_owner
  validate :user_in_same_family

  scope :with_permission, ->(permission) { where(permission: permission) }

  def full_control?
    permission == "full_control"
  end

  def read_write?
    permission == "read_write"
  end

  def read_only?
    permission == "read_only"
  end

  def can_annotate?
    full_control? || read_write?
  end

  def can_edit?
    full_control?
  end

  private

    def cannot_share_with_owner
      if account && user && account.owner_id == user_id
        errors.add(:user, "is already the owner of this account")
      end
    end

    def user_in_same_family
      if account && user && user.family_id != account.family_id
        errors.add(:user, "must be in the same family")
      end
    end
end
