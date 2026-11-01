class TruelayerItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  # UK banks release more than 90 days of history only while the customer is
  # present, which TrueLayer allows for about 5 minutes after consent. Stop a
  # little early so the last request doesn't straddle the cutoff.
  FULL_HISTORY_WINDOW = 4.5.minutes
  MAX_UNATTENDED_HISTORY_DAYS = 89
  # Refresh the access token when it has less than this left.
  TOKEN_REFRESH_BUFFER = 2.minutes

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :client_secret
    encrypts :access_token
    encrypts :refresh_token
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :client_id, presence: true
  validates :client_secret, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :truelayer_accounts, dependent: :destroy
  has_many :accounts, through: :truelayer_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :connected, -> { where.not(refresh_token: nil) }
  scope :syncable, -> { active.connected }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    client_id.present? && client_secret.present?
  end

  def connected?
    refresh_token.present?
  end

  def needs_authorization?
    !connected? || requires_update?
  end

  def sandbox?
    Provider::Truelayer.sandbox_client_id?(client_id)
  end

  # True in the few minutes after consent, when the bank serves full history.
  def full_history_available?
    last_authorized_at.present? && last_authorized_at > FULL_HISTORY_WINDOW.ago
  end

  def consent_expiring_soon?(within: 14.days)
    consent_expires_at.present? && consent_expires_at <= within.from_now
  end

  # The post-consent history backfill never finished and can no longer run,
  # because the first import started after the bank's window or the backfill
  # stopped on an error. Reconnecting opens a new window.
  def history_backfill_missed?
    connected? && last_authorized_at.present? && history_backfilled_at.nil? && !full_history_available?
  end

  # Yields a callable that returns a valid access token (see
  # #fresh_access_token). Calling it before every request keeps a long import,
  # such as the post-consent backfill, from outliving the token.
  def with_access_token
    raise Provider::Truelayer::TruelayerError.new("TrueLayer connection is not authorized", :not_connected) unless connected?

    yield method(:fresh_access_token)
  rescue Provider::Truelayer::TruelayerError => e
    mark_requires_update!(e.error_type.to_s) if e.reauth_required?
    raise
  end

  # A valid access token. It is refreshed under the row lock when it is about
  # to expire, or when `rejected` is the token a request was just refused
  # with. The lock serialises refreshes across the web and worker processes:
  # TrueLayer rotates the refresh token, so two concurrent refreshes would
  # invalidate each other. with_lock reloads the row, so tokens another
  # process rotated meanwhile are used as they are.
  def fresh_access_token(rejected: nil)
    with_lock do
      expiring = access_token.blank? || access_token_expires_at.nil? || access_token_expires_at <= TOKEN_REFRESH_BUFFER.from_now
      refresh_tokens! if expiring || (rejected.present? && access_token == rejected)
      access_token
    end
  end

  # Stores the tokens from a completed consent and pulls connection metadata.
  def complete_authorization!(code:, redirect_uri:)
    provider = truelayer_provider
    raise Provider::Truelayer::TruelayerError.new("TrueLayer credentials are not configured", :unauthorized) unless provider

    tokens = provider.exchange_code(code: code, redirect_uri: redirect_uri)
    refresh_token = tokens[:refresh_token] || self.refresh_token
    raise Provider::Truelayer::TruelayerError.new("TrueLayer returned no refresh token", :token_failed) if refresh_token.blank?

    update!(
      access_token: tokens[:access_token],
      refresh_token: refresh_token,
      access_token_expires_at: tokens[:expires_in].seconds.from_now,
      last_authorized_at: Time.current,
      # A new consent opens a new full-history window, so backfill again.
      history_backfilled_at: nil,
      status: :good,
      reauth_reason: nil
    )

    refresh_connection_metadata!(tokens[:access_token])
  end

  # Consent expiry and bank name, from /data/v1/me. Best effort.
  def refresh_connection_metadata!(token)
    me = truelayer_provider.get_me(token)
    provider_info = me[:provider] || {}
    attributes = { raw_institution_payload: me }
    attributes[:consent_expires_at] = Time.zone.parse(me[:consent_expires_at].to_s) if me[:consent_expires_at].present?
    attributes[:institution_id] = provider_info[:provider_id] if provider_info[:provider_id].present?
    if provider_info[:display_name].present?
      attributes[:institution_name] = provider_info[:display_name]
      attributes[:name] = provider_info[:display_name] if name.blank? || name == default_name
    end
    update!(attributes)
  rescue Provider::Truelayer::TruelayerError => e
    mark_requires_update!("consent_expired") if e.error_type == :consent_expired
    Rails.logger.warn "TruelayerItem #{id} - Could not refresh connection metadata: #{e.message}"
  rescue ArgumentError, TypeError => e
    Rails.logger.warn "TruelayerItem #{id} - Ignoring unparseable consent expiry: #{e.message}"
  end

  def mark_requires_update!(reason)
    update!(status: :requires_update, reauth_reason: reason)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error "TruelayerItem #{id} - Failed to flag connection for reauthorization: #{e.message}"
  end

  def default_name
    I18n.t("truelayer_items.default_name", default: "TrueLayer Connection")
  end

  def import_latest_truelayer_data
    TruelayerItem::Importer.new(self).import
  end

  def process_accounts
    return [] if truelayer_accounts.empty?

    truelayer_accounts.joins(:account).merge(Account.visible).map do |truelayer_account|
      result = TruelayerAccount::Processor.new(truelayer_account).process
      { truelayer_account_id: truelayer_account.id, success: true, result: result }
    rescue => e
      Rails.logger.error "TruelayerItem #{id} - Failed to process account #{truelayer_account.id}: #{e.message}"
      { truelayer_account_id: truelayer_account.id, success: false, error: e.message }
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.map do |account|
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
      { account_id: account.id, success: true }
    rescue => e
      Rails.logger.error "TruelayerItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def upsert_truelayer_snapshot!(accounts_snapshot)
    update!(raw_payload: accounts_snapshot)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total == 0
      I18n.t("truelayer_items.truelayer_item.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("truelayer_items.truelayer_item.sync_status.synced", count: linked)
    else
      I18n.t("truelayer_items.truelayer_item.sync_status.partial_setup", count: unlinked, linked: linked, unlinked: unlinked)
    end
  end

  def linked_accounts_count
    truelayer_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    truelayer_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    truelayer_accounts.count
  end

  def institution_display_name
    institution_name.presence || name
  end

  private

    def refresh_tokens!
      tokens = truelayer_provider.refresh_access_token(refresh_token)
      update!(
        access_token: tokens[:access_token],
        # TrueLayer may omit refresh_token on refresh; keep the current one.
        refresh_token: tokens[:refresh_token] || refresh_token,
        access_token_expires_at: tokens[:expires_in].seconds.from_now
      )
    end
end
