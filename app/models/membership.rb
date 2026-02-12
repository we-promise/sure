class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :family

  enum :role, { guest: "guest", member: "member", admin: "admin" }, validate: true

  validates :user_id, uniqueness: { scope: :family_id }
  validates :role, presence: true

  def admin?
    role == "admin" || user.super_admin?
  end
end
