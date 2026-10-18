class CaAutoBankItem < ApplicationRecord
  include Syncable, ProviderItemOwnable

  credential_scope :tenant_wide

  encrypts :authentication_token
  encrypts :account_identity
  encrypts :pending_login_state

  ERROR_CODES = %w[
    session_expired invalid_session invalid_response invalid_snapshot incomplete_snapshot
    account_identity_changed account_conflict stale_snapshot provider_unavailable rate_limited sync_failed
  ].freeze

  enum :status, { pending: "pending", connected: "connected", requires_update: "requires_update" }, default: :requires_update

  belongs_to :family
  belongs_to :owner, class_name: "User"
  has_many :ca_auto_bank_accounts, dependent: :destroy
  has_many :accounts, through: :ca_auto_bank_accounts

  validates :owner_id, uniqueness: { scope: :family_id }
  validates :status, inclusion: { in: statuses.keys }
  validate :credentials_require_encryption

  scope :ordered, -> { order(created_at: :desc) }
  # bank sessions cannot renew; keep this preview limited to owner-initiated syncs
  scope :syncable, -> { none }

  def session_configured?
    connected? && authentication_token.present? && account_identity.present? &&
      request_session_id.present? && session_expires_at.present? && session_expires_at > Time.current
  end
  alias credentials_configured? session_configured?

  def ready_for_sync?
    session_configured? && ActiveRecordEncryptionConfig.explicitly_configured? && owner&.active? &&
      owner.family_id == family_id && Rails.application.config.app_mode.self_hosted?
  end
  alias syncable? ready_for_sync?

  def reconnect_required?
    status == "requires_update" || (connected? && !session_configured?)
  end

  def requires_update?
    reconnect_required?
  end

  def name
    I18n.t("ca_auto_bank.name")
  end

  def provider
    Provider::CaAutoBank.new(authentication_token: authentication_token, request_session_id: request_session_id)
  end

  def last_synced_at
    snapshot_at
  end

  def error_message
    return I18n.t("ca_auto_bank.errors.session_expired") if reconnect_required? && snapshot_at.present?
    return if last_sync_error_code.blank?

    I18n.t("ca_auto_bank.errors.#{ERROR_CODES.include?(last_sync_error_code) ? last_sync_error_code : 'sync_failed'}")
  end

  def disconnect!
    with_lock do
      update!(authentication_token: nil, pending_login_state: nil, request_session_id: nil,
        session_expires_at: nil, status: :requires_update, connection_generation: connection_generation + 1)
    end
  end

  private

    def credentials_require_encryption
      return if ActiveRecordEncryptionConfig.explicitly_configured?
      return unless [ authentication_token, account_identity, pending_login_state ].any?(&:present?)

      errors.add(:base, :encryption_unavailable)
    end
end
