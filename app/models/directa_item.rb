class DirectaItem < ApplicationRecord
  include ProviderSyncPacing, Syncable, ProviderItemOwnable

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
    "rate_limited" => "Directa is temporarily limiting requests. Your saved data was kept.",
    "sync_failed" => "Directa portfolio syncing failed. Your previous data was kept. Retry or reconnect.",
    "history_incomplete" => "Directa activity history is incomplete. Existing entries were kept.",
    "history_invalid_data" => "Directa returned invalid activity history. Existing entries were kept.",
    "history_unsupported_activity" => "Directa returned an unsupported activity. Existing entries were kept.",
    "history_changed" => "Directa activity history changed within saved coverage. Existing entries were kept for review.",
    "history_identity_changed" => "The Directa account identity changed during activity history sync. Existing entries were kept.",
    "history_rate_limited" => "Directa is temporarily limiting activity history requests. Your saved data was kept.",
    "history_sync_failed" => "Directa activity history could not be synchronized. Your portfolio snapshot remains available."
  }.freeze

  SYNC_ERROR_CODES = SYNC_ERROR_MESSAGES.keys.freeze
  HISTORY_SYNC_ERROR_CODES = %w[
    history_incomplete history_invalid_data history_unsupported_activity history_changed
    history_identity_changed history_rate_limited history_sync_failed
  ].freeze

  enum :status, { pending: "pending", connected: "connected", requires_update: "requires_update" }, default: :requires_update

  belongs_to :family
  belongs_to :owner, class_name: "User"
  has_many :directa_accounts, dependent: :destroy
  has_many :accounts, through: :directa_accounts

  validates :owner_id, uniqueness: { scope: :family_id }
  validates :status, inclusion: { in: statuses.keys }
  validates :history_sync_error_code, inclusion: { in: HISTORY_SYNC_ERROR_CODES }, allow_nil: true
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

  def record_history_sync_failure!(code)
    safe_code = HISTORY_SYNC_ERROR_CODES.include?(code.to_s) ? code.to_s : "history_sync_failed"
    update!(history_sync_error_code: safe_code) if persisted?
  end

  def clear_history_sync_failure!
    update!(history_sync_error_code: nil) if persisted? && history_sync_error_code.present?
  end

  def last_history_sync_error
    SYNC_ERROR_MESSAGES[history_sync_error_code]
  end

  def sync_history_later
    return unless persisted? && ready_for_sync? && directa_account&.usable_account.present?

    DirectaHistorySyncJob.perform_later(id)
  rescue StandardError
    begin
      record_history_sync_failure!("history_sync_failed")
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Directa activity history could not be scheduled.",
        source: "directa",
        family: family,
        account_provider: directa_account&.account_provider,
        provider_key: "directa",
        metadata: { item_id: id, error_code: "history_sync_failed" }
      )
    rescue StandardError
      nil
    end
    nil
  end

  def last_sync_error
    return SYNC_ERROR_MESSAGES["rate_limited"] if sync_rate_limited?

    SYNC_ERROR_MESSAGES[last_sync_error_code] || SYNC_ERROR_MESSAGES[history_sync_error_code]
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

    def sync_attempt_column(lane)
      case lane.to_sym
      when :sync, :portfolio
        :last_sync_attempt_at
      when :history
        :last_history_sync_attempt_at
      else
        raise ArgumentError, "Unknown Directa sync lane"
      end
    end

    def sync_pacing_translation_scope
      "directa_items.sync"
    end

    def owner_belongs_to_family
      errors.add(:owner, :invalid) if owner && family_id.present? && owner.family_id != family_id
    end

    def require_explicit_encryption_for_credentials
      return unless [ broker_account, account_identity, multi_token, mono_token, pending_login_state ].any?(&:present?)
      return if ActiveRecordEncryptionConfig.explicitly_configured?

      errors.add(:base, :encryption_unavailable)
    end
end
