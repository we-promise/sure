module ProviderOwnable
  extend ActiveSupport::Concern

  included do
    belongs_to :created_by, class_name: "User", optional: true
    before_validation :assign_default_creator, on: :create
  end

  def created_by?(user)
    user.present? && created_by_id == user.id
  end

  private

    def assign_default_creator
      return if created_by.present?
      self.created_by = Current.user ||
        family&.users&.find_by(role: %w[admin super_admin]) ||
        family&.users&.order(:created_at)&.first
    end
end
