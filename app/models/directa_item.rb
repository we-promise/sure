class DirectaItem < ApplicationRecord
  include Syncable, ProviderItemOwnable

  credential_scope :tenant_wide

  encrypts :broker_account
  encrypts :account_identity
  encrypts :multi_token
  encrypts :mono_token
  encrypts :pending_login_state

  SYNC_ERROR_MESSAGES = {
    "account_conflict" => "The Directa account is not linked safely. Your previous data was kept.",
    "awaiting_valuation" => "Directa is connected. The first verified portfolio snapshot is still pending.",
    "partial_snapshot" => "Directa returned an incomplete portfolio snapshot. Your previous data was kept.",
    "account_identity_changed" => "Directa returned a different account identity. Your previous data was kept.",
    "invalid_snapshot" => "Directa returned an invalid portfolio snapshot. Your previous data was kept.",
    "duplicate_position" => "Directa returned duplicate position identities. Your previous data was kept.",
    "security_conflict" => "A Directa security identity conflicts with existing data. Your previous data was kept.",
    "holding_conflict" => "A Directa position conflicts with existing account data. Your previous data was kept.",
    "stale_snapshot" => "Directa returned an older portfolio snapshot. Your previous data was kept.",
    "sync_failed" => "Directa portfolio syncing failed. Your previous data was kept. Retry or reconnect."
  }.freeze

  SYNC_ERROR_CODES = SYNC_ERROR_MESSAGES.keys.freeze

  enum :status, { pending: "pending", connected: "connected", requires_update: "requires_update" }, default: :requires_update

  belongs_to :family
  belongs_to :owner, class_name: "User"
  has_many :directa_accounts, dependent: :destroy
  has_many :accounts, through: :directa_accounts

  validates :owner_id, uniqueness: { scope: :family_id }
  validates :status, inclusion: { in: statuses.keys }
  validate :owner_belongs_to_family
  validate :require_explicit_encryption_for_credentials

  scope :ordered, -> { order(created_at: :desc) }
  scope :syncable, -> { where(status: :connected) }

  def credentials_configured?
    session_configured?
  end

  def session_configured?
    connected? && broker_account.present? && account_identity.present? && multi_token.present? && mono_token.present?
  end

  def ready_for_sync?
    session_configured? && owner&.active? && ActiveRecordEncryptionConfig.explicitly_configured?
  end
  alias syncable? ready_for_sync?

  def waiting_for_first_snapshot?
    session_configured? && portfolio_snapshot_at.blank?
  end

  def last_synced_at
    portfolio_snapshot_at
  end

  def directa_account
    directa_accounts.first
  end

  def verified_session
    return unless session_configured?

    Provider::Directa::VerifiedSession.new(
      account_number: broker_account,
      account_identity: account_identity,
      multi_token: multi_token,
      mono_token: mono_token,
      host: Provider::Directa::HOST,
      connection_generation: connection_generation
    )
  end

  def provider
    session = verified_session
    Provider::Directa.new(session: session) if session
  end

  def start_login!(broker_account:, password:, session_id:)
    DirectaItem::Login.new(self).start(
      broker_account: broker_account,
      password: password,
      session_id: session_id
    )
  end

  def complete_login!(otp_code:, attempt_id:, session_id:)
    DirectaItem::Login.new(self).complete(
      otp_code: otp_code,
      attempt_id: attempt_id,
      session_id: session_id
    )
  end

  def cancel_login!(attempt_id:, session_id:)
    DirectaItem::Login.new(self).cancel(attempt_id: attempt_id, session_id: session_id)
  end

  def pending_login_summary(session_id:)
    DirectaItem::Login.new(self).summary(session_id: session_id)
  end

  def record_sync_failure!(code)
    safe_code = SYNC_ERROR_CODES.include?(code.to_s) ? code.to_s : "sync_failed"
    update!(last_sync_error_code: safe_code) if persisted?
  end

  def clear_sync_failure!
    update!(last_sync_error_code: nil) if persisted? && last_sync_error_code.present?
  end

  def last_sync_error
    SYNC_ERROR_MESSAGES[last_sync_error_code]
  end

  def disconnect!
    with_lock do
      update!(
        multi_token: nil,
        mono_token: nil,
        pending_login_state: nil,
        status: :requires_update,
        connection_generation: connection_generation + 1
      )
    end
  end

  private

    def owner_belongs_to_family
      errors.add(:owner, :invalid) if owner && family_id.present? && owner.family_id != family_id
    end

    def require_explicit_encryption_for_credentials
      return unless [ broker_account, account_identity, multi_token, mono_token, pending_login_state ].any?(&:present?)
      return if ActiveRecordEncryptionConfig.explicitly_configured?

      errors.add(:base, :encryption_unavailable)
    end
end
