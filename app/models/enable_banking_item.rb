class EnableBankingItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, LegacyWriterGuard

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :client_certificate, deterministic: true
    encrypts :session_id, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :country_code, presence: true
  validates :application_id, presence: true
  validates :client_certificate, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :enable_banking_accounts, dependent: :destroy
  has_many :accounts, through: :enable_banking_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later(actor: Current.user)
    Lifecycle.new(item: self, actor: actor).disconnect
  end

  def unlink_all!(dry_run: false, actor: Current.user)
    Lifecycle.new(item: self, actor: actor).unlink_all(dry_run: dry_run)
  end

  def credentials_configured?
    application_id.present? && client_certificate.present? && country_code.present?
  end

  def session_valid?
    good? && session_id.present? && (session_expires_at.nil? || session_expires_at > Time.current)
  end

  def session_expired?
    session_id.present? && session_expires_at.present? && session_expires_at <= Time.current
  end

  def needs_authorization?
    !session_valid?
  end

  # TODO: implement data retention policy for last_psu_ip (GDPR/CCPA — nullify after session expiry or 90 days)

  validate :psu_type_in_aspsp_types

  def psu_type_in_aspsp_types
    return if psu_type.blank? || aspsp_psu_types.blank?
    unless aspsp_psu_types.include?(psu_type)
      errors.add(:psu_type, "must be one of the ASPSP supported types")
    end
  end

  # OAuth state is generated and verified by the admitted lifecycle command.
  def start_authorization(aspsp_name:, redirect_url:, state: nil, psu_type: "personal",
                          aspsp_data: nil, language: nil, actor: Current.user, last_psu_ip: nil)
    Lifecycle.refuse! unless state.nil?
    Lifecycle.new(item: self, actor: actor).start_authorization(aspsp_name: aspsp_name,
      redirect_url: redirect_url, psu_type: psu_type, aspsp_data: aspsp_data, language: language, last_psu_ip: last_psu_ip)
  end

  def begin_authorization!(redirect_url:, state: nil, language: nil, psu_type: nil, aspsp_name: nil, actor: Current.user, last_psu_ip: nil)
    Lifecycle.refuse! unless state.nil?
    Lifecycle.new(item: self, actor: actor).begin_authorization!(redirect_url: redirect_url,
      language: language, psu_type: psu_type, aspsp_name: aspsp_name, last_psu_ip: last_psu_ip)
  end

  def complete_authorization(code:, state:, actor: Current.user, last_psu_ip: nil)
    Lifecycle.from_state(state, actor: actor, item: self).complete_authorization(code: code, last_psu_ip: last_psu_ip)
  end

  # Reconcile the locally-stored session expiry with what the API reports.
  # The session info returned by GET /sessions carries the authoritative
  # access.valid_until; persisting it on every sync keeps session_valid? accurate
  # and avoids both premature "expired" states and stale "still valid" states.
  def reconcile_session_expiry!(session_data, expected_context: nil)
    return unless session_data.is_a?(Hash)

    valid_until = session_data.dig(:access, :valid_until) || session_data.dig("access", "valid_until")
    return if valid_until.blank?

    parsed = Time.zone.parse(valid_until.to_s)
    return if parsed.nil? || parsed == session_expires_at

    context = EnableBankingItem::LegacyAccess.with_snapshot(self, expected_context: expected_context) do |current|
      current.update!(session_expires_at: parsed)
      EnableBankingItem::LegacyAccess.transport_context(current)
    end
    reload
    context
  rescue *EnableBankingItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue ArgumentError, TypeError, ActiveRecord::ActiveRecordError => e
    # Best-effort reconciliation: swallow bad timestamps (ArgumentError/TypeError)
    # as well as validation/locking failures from update! (RecordInvalid,
    # StaleObjectError) so a sync is never derailed by expiry bookkeeping.
    Rails.logger.warn "EnableBankingItem #{id} - Failed to reconcile session expiry: #{e.message}"
    nil
  end

  def import_latest_enable_banking_data
    EnableBankingItem::Importer.new(self).import
  rescue *EnableBankingItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue => e
    Rails.logger.error "EnableBankingItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts(expected_contexts: nil, expected_item_context: nil)
    expected_item_context ||= EnableBankingItem::LegacyAccess.transport_context(self)
    EnableBankingItem::LegacyAccess.with_item(self, operation: :publish) do |current|
      EnableBankingItem::LegacyAccess.verify_transport!(current, expected_item_context)
      current.send(:process_accounts_admitted, expected_contexts: expected_contexts, expected_item_context: expected_item_context)
    end
  end

  private def process_accounts_admitted(expected_contexts:, expected_item_context:)
    if expected_contexts
      unless expected_contexts.is_a?(Hash) && expected_contexts.keys.all? { |id| id.is_a?(String) } &&
          expected_contexts.keys.sort == enable_banking_accounts.order(:id).pluck(:id).sort
        raise EnableBankingItem::LegacyAccess::Fence::OwnershipChanged, "Enable Banking processing inventory changed after acquisition"
      end
      EnableBankingItem::LegacyAccess.bounded_sources(enable_banking_accounts).each do |source|
        EnableBankingItem::LegacyAccess.verify_source!(source, expected_contexts.fetch(source.id))
      end
    end
    return [] if enable_banking_accounts.empty?

    results = []
    EnableBankingItem::LegacyAccess.bounded_sources(enable_banking_accounts.joins(:account).merge(Account.visible)).each do |enable_banking_account|
      begin
        result = EnableBankingAccount::Processor.new(enable_banking_account,
          expected_context: expected_contexts&.fetch(enable_banking_account.id), expected_item_context: expected_item_context).process
        success = !result.is_a?(Hash) || result.with_indifferent_access[:success] != false
        results << { enable_banking_account_id: enable_banking_account.id, success: success, result: result }
      rescue *EnableBankingItem::LegacyAccess::DENIAL_ERRORS
        raise
      rescue => e
        Rails.logger.error "EnableBankingItem #{id} - Failed to process account #{enable_banking_account.id}: #{e.message}"
        results << { enable_banking_account_id: enable_banking_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    EnableBankingItem::LegacyAccess.with_item(self, operation: :publish, sync: parent_sync) do |current, admitted_sync|
      current.send(:schedule_account_syncs_admitted, parent_sync: admitted_sync,
        window_start_date: window_start_date, window_end_date: window_end_date)
    end
  end

  private def schedule_account_syncs_admitted(parent_sync:, window_start_date:, window_end_date:)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue *EnableBankingItem::LegacyAccess::DENIAL_ERRORS
        raise
      rescue => e
        Rails.logger.error "EnableBankingItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_enable_banking_snapshot!(accounts_snapshot = nil, expected_context: nil, **snapshot_fields)
    unless snapshot_fields.empty?
      raise ArgumentError, "Expected one Enable Banking snapshot" unless accounts_snapshot.nil?
      accounts_snapshot = snapshot_fields
    end
    EnableBankingItem::LegacyAccess.with_snapshot(self, expected_context: expected_context) do |current|
      current.update!(raw_payload: accounts_snapshot)
    end
    reload
    true
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def linked_accounts_count
    enable_banking_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    enable_banking_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    enable_banking_accounts.count
  end

  def sync_status_summary
    latest = latest_sync
    return nil unless latest

    if latest.sync_stats.present?
      stats = latest.sync_stats
      total = stats["total_accounts"] || 0
      linked = stats["linked_accounts"] || 0
      unlinked = stats["unlinked_accounts"] || 0

      if total == 0
        "No accounts found"
      elsif unlinked == 0
        "#{linked} #{'account'.pluralize(linked)} synced"
      else
        "#{linked} synced, #{unlinked} need setup"
      end
    else
      total_accounts = enable_banking_accounts.count
      linked_count = accounts.count
      unlinked_count = total_accounts - linked_count

      if total_accounts == 0
        "No accounts found"
      elsif unlinked_count == 0
        "#{linked_count} #{'account'.pluralize(linked_count)} synced"
      else
        "#{linked_count} synced, #{unlinked_count} need setup"
      end
    end
  end

  def institution_display_name
    aspsp_name.presence || institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    enable_banking_accounts.includes(:account)
                           .where.not(institution_metadata: nil)
                           .map { |acc| acc.institution_metadata }
                           .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      aspsp_name.presence || "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  def revoke_session(actor: Current.user)
    Lifecycle.new(item: self, actor: actor).revoke_session
  end

  private

    # Authentication approach preference, lowest number wins.
    # REDIRECT is the smoothest (PSU authenticates entirely on the ASPSP page).
    # DECOUPLED works through Enable Banking's hosted page (push-to-app / photoTAN
    # / chipTAN). EMBEDDED is last resort (handled by the hosted page too).
    AUTH_APPROACH_PRIORITY = { "REDIRECT" => 0, "DECOUPLED" => 1, "EMBEDDED" => 2 }.freeze

    # Choose the best authentication method for the given PSU type.
    # Returns a hash with :name and :approach, or nil when the ASPSP exposes no
    # API-selectable methods (Enable Banking then falls back to its default).
    def select_auth_method(aspsp_data, psu_type)
      methods = Array(aspsp_data[:auth_methods]).map(&:with_indifferent_access)
      return nil if methods.empty?

      # Hidden methods aren't surfaced on Enable Banking's hosted page, so we don't
      # auto-select one (the PSU couldn't complete it). If every method is hidden,
      # return nil and let /auth fall back to the ASPSP's default rather than
      # forcing a non-selectable method.
      methods = methods.reject { |m| ActiveModel::Type::Boolean.new.cast(m[:hidden_method]) }
      return nil if methods.empty?

      # Prefer methods that match the chosen PSU type; if none declare a psu_type
      # (or none match), consider all of them.
      matching = methods.select { |m| m[:psu_type].blank? || m[:psu_type].to_s == psu_type.to_s }
      candidates = matching.presence || methods

      best = candidates.min_by { |m| AUTH_APPROACH_PRIORITY.fetch(m[:approach].to_s, 99) }
      return nil unless best

      { name: best[:name], approach: best[:approach] }
    end

    def parse_session_expiry(session_result)
      if session_result[:access].present? && session_result[:access][:valid_until].present?
        parsed = Time.zone.parse(session_result[:access][:valid_until])
        parsed || 90.days.from_now
      else
        90.days.from_now
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.warn "Enable Banking session expiry could not be parsed"
      90.days.from_now
    end

end
