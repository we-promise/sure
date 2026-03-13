class MyfundItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :portfolio_name, presence: true

  belongs_to :family

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def credentials_configured?
    api_key.present? && portfolio_name.present?
  end

  def sync_status_summary
    if last_synced_at.present?
      "Last synced #{last_synced_at.strftime('%Y-%m-%d %H:%M')}"
    else
      "Never synced"
    end
  end
end
