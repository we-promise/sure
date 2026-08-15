class YaxiTicket < ApplicationRecord
  SERVICES = Provider::Yaxi::SERVICES.freeze

  belongs_to :family
  belongs_to :user

  validates :service, inclusion: { in: SERVICES }
  validates :expires_at, presence: true

  scope :active, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }

  def self.issue!(family:, user:, service:, service_data: nil)
    provider = Provider::YaxiAdapter.build_provider
    raise Provider::Yaxi::InvalidConfigurationError, "YAXI is not configured" unless provider

    expires_at = Provider::Yaxi::TICKET_LIFETIME.from_now
    record = create!(family: family, user: user, service: service, service_data: service_data, expires_at: expires_at)
    provider.issue_ticket(ticket_id: record.id, service: service, data: service_data, expires_at: expires_at)
  end

  def consume!
    with_lock do
      raise Provider::Yaxi::InvalidResultError, "YAXI ticket has already been used" if consumed_at.present?
      raise Provider::Yaxi::InvalidResultError, "YAXI ticket has expired" if expires_at <= Time.current

      update!(consumed_at: Time.current)
    end
  end
end
