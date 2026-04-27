class GocardlessItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  enum :sync_frequency, { manual: "manual", daily: "daily", twice_weekly: "twice_weekly", thrice_weekly: "thrice_weekly" }, default: :manual, prefix: :sync

  SYNC_FREQUENCY_OPTIONS = [
    [ "Manual only",        "manual"        ],
    [ "Daily (every 24 h)", "daily"         ],
    [ "Twice a week",       "twice_weekly"  ],
    [ "Three times a week", "thrice_weekly" ]
  ].freeze

  if encryption_ready?
    encrypts :access_token
    encrypts :refresh_token
  end

  validates :name, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :gocardless_accounts, dependent: :destroy
  has_many :accounts, through: :gocardless_accounts

  scope :active,       -> { where(scheduled_for_deletion: false) }
  scope :syncable,     -> { active }
  scope :ordered,      -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def bank_connected?
    requisition_id.present? && status == "good" && !agreement_expired?
  end

  def agreement_expired?
    agreement_expires_at.present? && agreement_expires_at < Time.current
  end

  def agreement_expiring_soon?
    agreement_expires_at.present? &&
      agreement_expires_at > Time.current &&
      agreement_expires_at < 14.days.from_now
  end

  def access_token_expired?
    access_token_expires_at.blank? || access_token_expires_at < 10.minutes.from_now
  end

  # Returns a ready-to-use SDK instance with a valid access token
  def gocardless_client
    ensure_valid_access_token!
    return nil unless access_token.present?
    Provider::Gocardless.new(nil, nil).with_token(access_token)
  end

  def import_latest_gocardless_data
    client = gocardless_client
    unless client
      Rails.logger.error "GocardlessItem #{id} - Cannot import: client could not be initialised"
      raise StandardError, "GoCardless client could not be initialised — check credentials"
    end

    GocardlessItem::Importer.new(self, client: client).import
  rescue => e
    Rails.logger.error "GocardlessItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if gocardless_accounts.empty?

    results = []
    gocardless_accounts.joins(:account).merge(Account.visible).each do |gc_account|
      begin
        GocardlessAccount::Processor.new(gc_account).process
        results << { gocardless_account_id: gc_account.id, success: true }
      rescue => e
        Rails.logger.error "GocardlessItem #{id} - Failed to process account #{gc_account.id}: #{e.message}"
        results << { gocardless_account_id: gc_account.id, success: false, error: e.message }
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
          parent_sync:       parent_sync,
          window_start_date: window_start_date,
          window_end_date:   window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "GocardlessItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def linked_accounts_count
    gocardless_accounts.linked.count
  end

  def unlinked_accounts_count
    gocardless_accounts.unlinked.count
  end

  def skipped_accounts_count
    gocardless_accounts.skipped.count
  end

  def total_accounts_count
    gocardless_accounts.active.count
  end

  def institution_display_name
    institution_name.presence || name
  end

  private

    def ensure_valid_access_token!
      return unless access_token_expired?

      if refresh_token.present?
        refresh_access_token!
      else
        update!(status: :requires_update)
      end
    end

    def refresh_access_token!
      secret_id  = Provider::GocardlessAdapter.config_value(:secret_id)
      secret_key = Provider::GocardlessAdapter.config_value(:secret_key)
      sdk        = Provider::Gocardless.new(secret_id, secret_key)
      result     = sdk.refresh_access_token(refresh_token)

      # GoCardless returns a new refresh token on every refresh call — must save it
      # or the 31-day refresh token will expire and force full re-authorisation.
      update!(
        access_token:            result["access"],
        access_token_expires_at: result["access_expires"].seconds.from_now,
        refresh_token:           result["refresh"]
      )
    rescue Provider::Gocardless::AuthError
      update!(status: :requires_update)
      Rails.logger.error "GocardlessItem #{id} - Token refresh failed"
    end
end