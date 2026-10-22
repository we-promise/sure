class SaxoItem < ApplicationRecord
  include Syncable, Encryptable, DestroyableLater

  encrypts :access_token
  encrypts :refresh_token

  belongs_to :family
  has_many :saxo_accounts, dependent: :destroy
  has_many :accounts, through: :saxo_accounts
  has_many :saxo_authorizations, dependent: :destroy

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where(status: "good").where.not(refresh_token: nil) }
  scope :ordered, -> { order(created_at: :desc) }
  validates :name, :sync_start_date, presence: true

  def access_token!(force_refresh: false, rejected_token: nil)
    attempted_refresh_token = nil
    with_lock do
      attempted_refresh_token = refresh_token
      unless application_key_digest == Provider::Saxo.application_key_digest && refresh_token.present? && refresh_expires_at&.future?
        raise Provider::Saxo::AuthenticationError, "Saxo authorization expired; reconnect"
      end
      force_refresh = false if rejected_token.present? && access_token.present? && access_token != rejected_token
      if force_refresh || access_token.blank? || access_expires_at.nil? || [ access_expires_at, refresh_expires_at ].min <= 6.minutes.from_now
        renewed = Provider::Saxo.exchange(grant_type: "refresh_token", refresh_token: refresh_token)
        update!(renewed.merge(status: :good))
      end
      access_token
    end
  rescue Provider::Saxo::AuthenticationError
    with_lock { update!(status: :requires_update) if refresh_token == attempted_refresh_token }
    raise
  end

  def saxo_provider
    Provider::Saxo.new(self)
  end

  def syncer
    SaxoItem::Syncer.new(self)
  end

  def credentials_configured?
    refresh_token.present? && Provider::Saxo.configured?
  end

  def institution_name
    "Saxo Bank"
  end

  def institution_domain
    "home.saxo"
  end

  def linked_accounts
    accounts
  end

  def linked_accounts_count
    accounts.count
  end

  def total_accounts_count
    saxo_accounts.count
  end

  def unlinked_accounts_count
    saxo_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def has_completed_initial_setup?
    accounts.exists?
  end

  def disconnect!
    with_lock do
      saxo_accounts.each { |provider_account| provider_account.account_provider&.destroy! }
      update!(access_token: nil, refresh_token: nil, access_expires_at: nil,
        refresh_expires_at: nil, status: :requires_update)
    end
    destroy_later
  end
end
