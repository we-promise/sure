class TraderepublicItem < ApplicationRecord
  include Syncable, Provided

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good, prefix: true

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :phone_number, deterministic: true
    encrypts :pin, deterministic: true
    encrypts :session_token, deterministic: true
    encrypts :refresh_token, deterministic: true
  end

  validates :name, presence: true
  validates :phone_number, presence: true, on: :create
  validates :phone_number, format: { with: /\A\+\d{10,15}\z/, message: "must be in international format (e.g., +491234567890)" }, on: :create, if: :phone_number_changed?
  validates :pin, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo

  has_many :traderepublic_accounts, dependent: :destroy
  has_many :accounts, through: :traderepublic_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_traderepublic_data(skip_token_refresh: false, sync: nil)
    provider = traderepublic_provider
    unless provider
      Rails.logger.error "TraderepublicItem #{id} - Cannot import: TradeRepublic provider is not configured (missing credentials)"
      raise StandardError.new("TradeRepublic provider is not configured")
    end

    # Try import with current tokens
    TraderepublicItem::Importer.new(self, traderepublic_provider: provider).import
  rescue TraderepublicError => e
    # If authentication failed and we have credentials, try re-authenticating automatically
    if [:unauthorized, :auth_failed].include?(e.error_code) && !skip_token_refresh && credentials_configured?
      Rails.logger.warn "TraderepublicItem #{id} - Authentication failed, attempting automatic re-authentication"
      
      if auto_reauthenticate
        Rails.logger.info "TraderepublicItem #{id} - Re-authentication successful, retrying import"
        # Retry import with fresh tokens (skip_token_refresh to avoid infinite loop)
        return import_latest_traderepublic_data(skip_token_refresh: true)
      else
        Rails.logger.error "TraderepublicItem #{id} - Automatic re-authentication failed"
        update!(status: :requires_update)
        raise StandardError.new("Session expired and automatic re-authentication failed. Please log in again manually.")
      end
    else
      Rails.logger.error "TraderepublicItem #{id} - Failed to import data: #{e.message}"
      raise
    end
  rescue => e
    Rails.logger.error "TraderepublicItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def credentials_configured?
    phone_number.present? && pin.present?
  end

  def session_configured?
    session_token.present?
  end

  def traderepublic_provider
    return nil unless credentials_configured?

    @traderepublic_provider ||= Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin,
      session_token: session_token,
      refresh_token: refresh_token,
      raw_cookies: session_cookies
    )
  end

  # Initiate login and store processId
  def initiate_login!
    provider = Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin
    )

    result = provider.initiate_login
    update!(
      process_id: result["processId"],
      session_cookies: { jsessionid: provider.jsessionid }.compact
    )
    result
  end

  # Complete login with device PIN
  def complete_login!(device_pin)
    raise "No processId found" unless process_id

    provider = Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin
    )
    provider.process_id = process_id
    provider.jsessionid = session_cookies&.dig("jsessionid") if session_cookies.is_a?(Hash)

    provider.verify_device_pin(device_pin)

    # Save session data
    update!(
      session_token: provider.session_token,
      refresh_token: provider.refresh_token,
      session_cookies: provider.raw_cookies,
      process_id: nil, # Clear processId after successful login
      status: :good
    )

    true
  rescue => e
    Rails.logger.error "TraderepublicItem #{id}: Login failed - #{e.message}"
    update!(status: :requires_update)
    false
  end

  # Check if login needs to be completed
  def pending_login?
    process_id.present? && session_token.blank?
  end

  # Automatic re-authentication when tokens expire
  # Trade Republic doesn't support token refresh, so we need to re-authenticate from scratch
  def auto_reauthenticate
    Rails.logger.info "TraderepublicItem #{id}: Starting automatic re-authentication"
    
    unless credentials_configured?
      Rails.logger.error "TraderepublicItem #{id}: Cannot auto re-authenticate - credentials not configured"
      return false
    end

    begin
      # Step 1: Initiate login to get processId
      result = initiate_login!
      
      Rails.logger.info "TraderepublicItem #{id}: Login initiated, processId: #{process_id}"
      
      # Trade Republic requires SMS verification - we can't auto-complete this step
      # Mark as requires_update so user knows they need to re-authenticate
      Rails.logger.warn "TraderepublicItem #{id}: SMS verification required - automatic re-authentication cannot proceed"
      update!(status: :requires_update)
      
      false
    rescue => e
      Rails.logger.error "TraderepublicItem #{id}: Automatic re-authentication failed - #{e.message}"
      false
    end
  end

  def syncer
    @syncer ||= TraderepublicItem::Syncer.new(self)
  end

  def process_accounts
    # Process each account's transactions and create entries
    traderepublic_accounts.includes(:linked_account).each do |tr_account|
      next unless tr_account.linked_account

      TraderepublicAccount::Processor.new(tr_account).process
    end
  end

  def schedule_account_syncs(parent_sync:, window_start_date: nil, window_end_date: nil)
    # Trigger balance calculations for linked accounts
    traderepublic_accounts.joins(:account).merge(Account.visible).each do |tr_account|
      tr_account.linked_account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end
end
