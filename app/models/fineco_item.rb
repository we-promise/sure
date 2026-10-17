class FinecoItem < ApplicationRecord
  class PortfolioImportError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code.to_s
      super(SYNC_ERROR_MESSAGES.fetch(@code, SYNC_ERROR_MESSAGES.fetch("sync_failed")))
    end
  end

  SYNC_ERROR_MESSAGES = {
    "reauthentication_required" => "Reconnect Fineco to resume investment syncing.",
    "disconnected" => "Fineco portfolio syncing is paused. Reconnect to resume updates.",
    "identity_verification_required" => "Fineco account identity verification is required before investment syncing can start.",
    "account_identity_changed" => "The selected Fineco account or dossier changed. Reconnect the original account before syncing.",
    "invalid_snapshot" => "Fineco returned an incomplete portfolio snapshot. Your previous holdings and balance were kept.",
    "quote_data_unavailable" => "Fineco temporarily omitted market prices from its portfolio response. Your previous holdings and balance were kept.",
    "partial_snapshot" => "Fineco returned a filtered portfolio snapshot. Your previous holdings and balance were kept.",
    "unsupported_position" => "Fineco returned an unsupported position. Your previous holdings and balance were kept.",
    "duplicate_position" => "Fineco returned ambiguous position identities. Your previous holdings and balance were kept.",
    "security_conflict" => "A Fineco security identity conflicts with existing data. Your previous holdings and balance were kept.",
    "holding_conflict" => "A Fineco position conflicts with existing account data. Your previous holdings and balance were kept.",
    "account_content_conflict" => "The Fineco Investment account contains unrelated manual activity or holdings. Your previous data was kept.",
    "account_conflict" => "The Fineco Investment account is not linked safely. Your previous holdings and balance were kept.",
    "stale_snapshot" => "Fineco returned an older portfolio snapshot. Your previous holdings and balance were kept.",
    "encryption_unavailable" => "Fineco syncing requires application encryption to be configured.",
    "history_sync_failed" => "Fineco investment history could not be refreshed. Your saved activity and portfolio were kept.",
    "history_incomplete" => "Fineco returned incomplete investment history. Your saved activity was kept.",
    "history_inconsistent" => "Fineco investment history changed during retrieval. Your saved activity was kept; retry the sync.",
    "history_changed" => "Fineco changed previously imported investment history. Your saved activity was kept for review.",
    "history_invalid_data" => "Fineco returned invalid investment activity. Your saved activity was kept.",
    "history_unsupported_activity" => "Fineco returned investment activity that cannot be imported safely. Your saved activity was kept.",
    "history_identity_changed" => "The Fineco account or dossier changed while reading investment history. Reconnect the original account.",
    "sync_failed" => "Fineco portfolio syncing failed. Your previous holdings and balance were kept. Retry or reconnect."
  }.freeze

  SYNC_ERROR_CODES = SYNC_ERROR_MESSAGES.keys.freeze

  include Syncable, ProviderItemOwnable

  credential_scope :tenant_wide

  encrypts :gsessionid
  encrypts :account_index
  encrypts :dossier_index
  encrypts :bank_account_number
  encrypts :dossier_identity

  belongs_to :family
  has_many :fineco_accounts, dependent: :destroy
  has_many :accounts, through: :fineco_accounts

  scope :ordered, -> { order(created_at: :desc) }
  scope :syncable, -> {
    linked_account_ids = FinecoAccount
      .joins(:fineco_item, :account_provider)
      .joins("INNER JOIN accounts ON accounts.id = account_providers.account_id")
      .joins("INNER JOIN users ON users.id = fineco_items.owner_id")
      .where(accounts: { accountable_type: "Investment", currency: "EUR", status: "active", disabled_at: nil })
      .where(users: { active: true })
      .where("accounts.family_id = fineco_items.family_id AND accounts.owner_id = fineco_items.owner_id")
      .where(
        "NOT EXISTS (SELECT 1 FROM account_providers additional_providers " \
        "WHERE additional_providers.account_id = accounts.id " \
        "AND additional_providers.id <> account_providers.id)"
      )
      .select(:fineco_item_id)
    where(status: :good, id: Provider::Fineco.verified_identity_contract? ? linked_account_ids : [])
  }

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  validates :gsessionid, presence: true, unless: :requires_update?
  validates :account_index, :dossier_index, :captured_at, :bank_account_number, :dossier_identity, presence: true
  validates :account_index, :dossier_index, format: { with: Provider::Fineco::INDEX_PATTERN }
  validates :dossier_identity, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :bank_account_number, length: { maximum: 128 }
  validates :owner_id, uniqueness: { scope: :family_id }, allow_nil: true
  validate :require_explicit_encryption_for_credentials

  def fineco_account
    fineco_accounts.find_by(external_id: FinecoAccount::EXTERNAL_ID)
  end

  def linked_account
    fineco_account&.current_account
  end

  def session_configured?
    gsessionid.present? && account_index.present? && dossier_index.present? &&
      bank_account_number.present? && dossier_identity.present?
  end

  def credentials_configured?
    session_configured?
  end

  def ready_for_sync?
    Provider::Fineco.verified_identity_contract? && good? && session_configured? && owner&.active? &&
      account_link_ready? && ActiveRecordEncryptionConfig.explicitly_configured?
  end

  def account_link_ready?
    fineco_account&.usable_account.present?
  end

  def syncable?
    ready_for_sync?
  end

  def sync_later(**options)
    sync = super
    sync_history_later
    sync
  end

  def sync_history_later
    return unless ready_for_sync?

    FinecoHistorySyncJob.perform_later(self)
  rescue StandardError
    update!(history_sync_error_code: "history_sync_failed")
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Fineco investment history could not be scheduled.",
      source: "fineco",
      provider_key: "fineco",
      family: family,
      metadata: { fineco_item_id: id }
    )
    nil
  end

  def same_bank_identity?(account_number:, dossier_identity:)
    bank_account_number.present? && self.dossier_identity.present? &&
      bank_account_number == account_number.to_s && self.dossier_identity == dossier_identity.to_s
  end

  def same_account_context?(account_index:, dossier_index:)
    self.account_index == account_index.to_s && self.dossier_index == dossier_index.to_s
  end

  def import_portfolio_snapshot!(payload:, captured_at:, parent_sync: nil, window_start_date: nil, window_end_date: nil, allow_account_bootstrap: false)
    raise PortfolioImportError.new(:identity_verification_required) unless Provider::Fineco.verified_identity_contract?
    raise PortfolioImportError.new(:encryption_unavailable) unless ActiveRecordEncryptionConfig.explicitly_configured?
    raise PortfolioImportError.new(:reauthentication_required) unless good? && session_configured?

    FinecoItem::Importer.new(self).import(
      payload: payload,
      captured_at: captured_at,
      parent_sync: parent_sync,
      window_start_date: window_start_date,
      window_end_date: window_end_date,
      allow_account_bootstrap: allow_account_bootstrap || new_record?
    )
  end

  def require_reauthentication!(code: "reauthentication_required")
    safe_code = SYNC_ERROR_CODES.include?(code.to_s) ? code.to_s : "reauthentication_required"
    update!(gsessionid: nil, status: :requires_update, last_sync_error_code: safe_code)
  end

  def record_sync_failure!(code)
    safe_code = SYNC_ERROR_CODES.include?(code.to_s) ? code.to_s : "sync_failed"
    update!(last_sync_error_code: safe_code) if persisted?
  end

  def clear_sync_failure!
    update!(last_sync_error_code: nil) if persisted? && last_sync_error_code.present?
  end

  def last_sync_error
    SYNC_ERROR_MESSAGES[last_sync_error_code].presence || SYNC_ERROR_MESSAGES[history_sync_error_code]
  end

  def sync_error
    last_sync_error.presence || super
  end

  def last_synced_at
    portfolio_snapshot_at.presence || super
  end

  def disconnect!
    with_lock do
      update!(
        gsessionid: nil,
        status: :requires_update,
        last_sync_error_code: "disconnected",
        connection_generation: connection_generation + 1
      )
    end
  end

  private

    def require_explicit_encryption_for_credentials
      return unless gsessionid.present? || account_index.present? || dossier_index.present? ||
        bank_account_number.present? || dossier_identity.present?
      return if ActiveRecordEncryptionConfig.explicitly_configured?

      errors.add(:base, :encryption_unavailable)
    end
end
