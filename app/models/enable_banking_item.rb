class EnableBankingItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

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

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def credentials_configured?
    application_id.present? && client_certificate.present? && country_code.present?
  end

  def session_valid?
    session_id.present? && (session_expires_at.nil? || session_expires_at > Time.current)
  end

  def session_expired?
    session_id.present? && session_expires_at.present? && session_expires_at <= Time.current
  end

  def needs_authorization?
    !session_valid?
  end

  # Start the OAuth authorization flow
  # Returns a redirect URL for the user
  def start_authorization(aspsp_name:, redirect_url:, state: nil)
    provider = enable_banking_provider
    raise StandardError.new("Enable Banking provider is not configured") unless provider

    result = provider.start_authorization(
      aspsp_name: aspsp_name,
      aspsp_country: country_code,
      redirect_url: redirect_url,
      state: state
    )

    # Store the authorization ID for later use
    update!(
      authorization_id: result[:authorization_id],
      aspsp_name: aspsp_name
    )

    result[:url]
  end

  # Complete the authorization flow with the code from callback
  def complete_authorization(code:)
    provider = enable_banking_provider
    raise StandardError.new("Enable Banking provider is not configured") unless provider

    result = provider.create_session(code: code)

    # Store session information
    update!(
      session_id: result[:session_id],
      session_expires_at: parse_session_expiry(result),
      authorization_id: nil,  # Clear the authorization ID
      status: :good
    )

    # Import the accounts from the session
    import_accounts_from_session(result[:accounts] || [])

    result
  end

  def import_latest_enable_banking_data
    provider = enable_banking_provider
    unless provider
      Rails.logger.error "EnableBankingItem #{id} - Cannot import: Enable Banking provider is not configured"
      raise StandardError.new("Enable Banking provider is not configured")
    end

    unless session_valid?
      Rails.logger.error "EnableBankingItem #{id} - Cannot import: Session is not valid"
      update!(status: :requires_update)
      raise StandardError.new("Enable Banking session is not valid or has expired")
    end

    EnableBankingItem::Importer.new(self, enable_banking_provider: provider).import
  rescue => e
    Rails.logger.error "EnableBankingItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if enable_banking_accounts.empty?

    results = []
    enable_banking_accounts.joins(:account).merge(Account.visible).each do |enable_banking_account|
      begin
        result = EnableBankingAccount::Processor.new(enable_banking_account).process
        results << { enable_banking_account_id: enable_banking_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "EnableBankingItem #{id} - Failed to process account #{enable_banking_account.id}: #{e.message}"
        results << { enable_banking_account_id: enable_banking_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
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
      rescue => e
        Rails.logger.error "EnableBankingItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_enable_banking_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
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

  # Revoke the session with Enable Banking
  def revoke_session
    return unless session_id.present?

    provider = enable_banking_provider
    return unless provider

    begin
      provider.delete_session(session_id: session_id)
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.warn "EnableBankingItem #{id} - Failed to revoke session: #{e.message}"
    ensure
      update!(
        session_id: nil,
        session_expires_at: nil,
        authorization_id: nil
      )
    end
  end

  private

    def parse_session_expiry(session_result)
      # Enable Banking sessions typically last 90 days
      # The exact expiry depends on the ASPSP consent
      if session_result[:access].present? && session_result[:access][:valid_until].present?
        Time.parse(session_result[:access][:valid_until])
      else
        90.days.from_now
      end
    rescue => e
      Rails.logger.warn "EnableBankingItem #{id} - Failed to parse session expiry: #{e.message}"
      90.days.from_now
    end

    def import_accounts_from_session(accounts_data)
      return if accounts_data.blank?

      accounts_data.each do |account_data|
        # Use identification_hash as the stable identifier across sessions
        uid = account_data[:identification_hash] || account_data[:uid]
        next unless uid.present?

        enable_banking_account = enable_banking_accounts.find_or_initialize_by(uid: uid)
        enable_banking_account.upsert_enable_banking_snapshot!(account_data)
        enable_banking_account.save!
      end
    end
end
