class ScalableCapitalItem < ApplicationRecord
  include Syncable

  SOURCE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/
  CLI_LOCK_KEY = 439_927_190_381_238_853
  BROKER_HISTORY_VERSION = 1

  belongs_to :family
  belongs_to :owner, class_name: "User", optional: true

  validate :owner_in_family
  validate :has_selected_source
  has_many :scalable_capital_accounts, dependent: :destroy
  has_many :accounts, through: :scalable_capital_accounts

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  validates :family_id, uniqueness: true
  validates :portfolio_id, :savings_id, format: { with: SOURCE_ID_PATTERN }, allow_nil: true

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

  def self.with_cli_lock
    with_connection do |connection|
      unless connection.select_value("SELECT pg_try_advisory_lock(#{CLI_LOCK_KEY})")
        raise Provider::ScalableCapital::Error, "Another Scalable Capital operation is running"
      end

      begin
        yield
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{CLI_LOCK_KEY})")
      end
    end
  end

  def name
    "Scalable Capital"
  end

  def savings_owner_kind
    "personal"
  end

  def auto_discover_savings?
    true
  end

  def broker_history_start
    return broker_synced_through if broker_history_version >= BROKER_HISTORY_VERSION || broker_synced_through.nil?

    [ broker_synced_through, created_at - 90.days ].min
  end

  def configured?
    self.class.configured_family_id == family_id
  end

  private

    def owner_in_family
      errors.add(:owner, :invalid) if owner && owner.family_id != family_id
    end

    def has_selected_source
      errors.add(:base, :invalid) if portfolio_id.blank? && selected_sources.blank?
    end
end
