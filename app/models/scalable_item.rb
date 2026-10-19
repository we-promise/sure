class ScalableItem < ApplicationRecord
  include Syncable, ProviderItemOwnable

  credential_scope :tenant_wide

  encrypts :credentials
  encrypts :person_identity
  encrypts :pending_login_state

  ERROR_CODES = %w[
    authentication_failed invalid_response session_expired provider_unavailable rate_limited
    encryption_unavailable login_in_progress challenge_expired challenge_not_available
    login_authorization_changed account_identity_changed account_conflict invalid_snapshot
    incomplete_snapshot unsupported_account stale_snapshot sync_failed
    history_incomplete history_changed history_unsupported
  ].freeze

  enum :status, { pending: "pending", connected: "connected", requires_update: "requires_update" }, default: :requires_update

  belongs_to :family
  belongs_to :owner, class_name: "User"
  has_many :scalable_accounts, dependent: :destroy
  has_many :accounts, through: :scalable_accounts

  validates :owner_id, uniqueness: { scope: :family_id }
  validate :credentials_require_encryption

  scope :ordered, -> { order(created_at: :desc) }
  scope :syncable, -> { where(status: :connected).where("next_sync_at IS NULL OR next_sync_at <= ?", Time.current) }

  def name
    I18n.t("scalable.name")
  end

  def credentials_data
    value = JSON.parse(credentials) if credentials.present?
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError, TypeError
    {}
  end

  def session_configured?
    data = credentials_data
    status == "connected" && person_identity.present? && data["person_id"] == person_identity &&
      %w[access_token refresh_token private_key_pem].all? { |key| data[key].is_a?(String) && data[key].present? }
  end
  alias credentials_configured? session_configured?

  def ready_for_sync?
    session_configured? && ActiveRecordEncryptionConfig.explicitly_configured? &&
      authorized_owner? && Rails.application.config.app_mode.self_hosted?
  end
  alias syncable? ready_for_sync?

  def sync_due?
    ready_for_sync? && (next_sync_at.nil? || next_sync_at <= Time.current)
  end

  def requires_update?
    status == "requires_update" || (status == "connected" && !session_configured?)
  end

  def last_synced_at
    snapshot_at
  end

  def error_message
    return if last_sync_error_code.blank?

    I18n.t("scalable.errors.#{safe_error_code(last_sync_error_code)}")
  end

  def start_login!(session_id:)
    Login.new(self).start(session_id: session_id)
  end

  def poll_login!(attempt_id:, session_id:)
    Login.new(self).poll(attempt_id: attempt_id, session_id: session_id)
  end

  def cancel_login!(attempt_id:, session_id:)
    Login.new(self).cancel(attempt_id: attempt_id, session_id: session_id)
  end

  def pending_login_summary(session_id:)
    Login.new(self).summary(session_id: session_id)
  end

  def disconnect!
    with_lock do
      update!(credentials: nil, pending_login_state: nil, status: :requires_update,
        connection_generation: connection_generation + 1, next_sync_at: nil)
    end
  end

  def record_sync_failure!(code)
    update!(last_sync_error_code: safe_error_code(code))
  end

  def authorized_owner?
    user = User.find_by(id: owner_id, family_id: family_id)
    user&.active? && user.admin? && user.preview_features_enabled?
  end

  def with_authenticated_provider
    result = failure = nil
    current_owner = User.find_by(id: owner_id, family_id: family_id)
    raise Provider::Scalable::Error.new(:login_authorization_changed) unless current_owner

    current_owner.with_lock do
      with_lock do
        rotated = nil
        begin
          raise Provider::Scalable::Error.new(:encryption_unavailable) unless ActiveRecordEncryptionConfig.explicitly_configured?
          raise Provider::Scalable::Error.new(:session_expired) unless ready_for_sync?
          next if next_sync_at.present? && next_sync_at > Time.current

          original_key = credentials_data.fetch("private_key_pem")
          persist_rotation = lambda do |data|
            unless data.is_a?(Hash) && data["person_id"] == person_identity && data["private_key_pem"] == original_key
              raise Provider::Scalable::Error.new(:account_identity_changed)
            end
            rotated = data.deep_dup
            update!(credentials: JSON.generate(rotated))
          end
          client = Provider::Scalable.new(credentials: credentials_data, on_credentials_update: persist_rotation)
          client.refresh_if_needed!
          transaction(requires_new: true) { result = yield(client) }
        rescue Provider::Scalable::Error => error
          reload
          failure = Provider::Scalable::Error.new(safe_error_code(error.code))
        rescue StandardError
          reload
          failure = Provider::Scalable::Error.new(:sync_failed)
        ensure
          # a later import rollback must not lose an already rotated refresh token
          update!(credentials: JSON.generate(rotated)) if rotated
          if failure
            attributes = { last_sync_error_code: safe_error_code(failure.code) }
            attributes[:status] = :requires_update if %w[session_expired account_identity_changed].include?(failure.code)
            attributes[:next_sync_at] = 15.minutes.from_now if %w[rate_limited provider_unavailable].include?(failure.code)
            update!(attributes)
            DebugLogEntry.capture(category: "provider_sync", level: "warn", source: "scalable",
              provider_key: "scalable", family: family,
              message: "Scalable synchronization could not be completed. Saved account data was kept.",
              metadata: { item_id: id, error_code: failure.code })
          end
        end
      end
    end
    raise failure if failure

    result
  end

  private

    def safe_error_code(code)
      ERROR_CODES.include?(code.to_s) ? code.to_s : "sync_failed"
    end

    def credentials_require_encryption
      return if ActiveRecordEncryptionConfig.explicitly_configured?
      return unless [ credentials, person_identity, pending_login_state ].any?(&:present?)

      errors.add(:base, :encryption_unavailable)
    end
end
