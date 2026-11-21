class ScalableCapitalItem < ApplicationRecord
  include Syncable

  SOURCE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/

  belongs_to :family
  belongs_to :owner, class_name: "User", optional: true

  validate :owner_in_family
  has_many :scalable_capital_accounts, dependent: :destroy
  has_many :accounts, through: :scalable_capital_accounts

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  validates :family_id, uniqueness: true
  validates :portfolio_id, presence: true, format: { with: SOURCE_ID_PATTERN }
  validates :savings_id, format: { with: SOURCE_ID_PATTERN }, allow_nil: true

  scope :ordered, -> { order(created_at: :desc) }
  scope :syncable, -> {
    family_id = configured_family_id
    family_id ? where(family_id: family_id) : none
  }

  def self.valid_source_id?(value)
    value.is_a?(String) && SOURCE_ID_PATTERN.match?(value)
  end

  def self.configured_family_id
    return unless Rails.application.config.app_mode.self_hosted? && Provider::ScalableCapital.executable&.start_with?("/")

    id = ENV["SCALABLE_CAPITAL_FAMILY_ID"]
    id if id&.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
  end

  def name
    "Scalable Capital"
  end

  def configured?
    self.class.configured_family_id == family_id
  end

  private

    def owner_in_family
      errors.add(:owner, :invalid) if owner && owner.family_id != family_id
    end
end
