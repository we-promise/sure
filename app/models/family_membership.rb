class FamilyMembership < ApplicationRecord
  belongs_to :user, inverse_of: :family_memberships
  belongs_to :family, inverse_of: :family_memberships

  VALID_ROLES = %w[admin member guest].freeze

  validates :user_id, uniqueness: { scope: :family_id }
  validates :role, presence: true, inclusion: { in: VALID_ROLES }
  validates :role, presence: true

  scope :admins, -> { where(role: "admin") }
  scope :ordered, -> { order(created_at: :asc) }

  def admin?
    role == "admin"
  end

  def member?
    role == "member"
  end

  def guest?
    role == "guest"
  end
end
