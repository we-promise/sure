class MoomooItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  # Refresh the access token when it has less than this left.
  TOKEN_REFRESH_BUFFER = 5.minutes
  # moomoo ends a connection after 14 days without use; warn before that.
  INACTIVITY_WARNING = 10.days
  # Consents started this soon after a client was registered for them reuse
  # it, so retries don't pile up clients; moomoo may have since dropped an
  # older one that was never used.
  PENDING_CLIENT_REUSE = 15.minutes

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :access_token
    encrypts :refresh_token
    encrypts :oauth_registration_access_token
    # Lists the ids of the trading accounts the user shared.
    encrypts :oauth_scope
    # Holds registration tokens too; see #oauth_client_for_consent!.
    encrypts :pending_oauth_client
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :moomoo_accounts, dependent: :destroy
  # Only securities accounts can be linked; the others are listed as unsupported.
  has_many :linkable_moomoo_accounts, -> { securities }, class_name: "MoomooAccount", inverse_of: :moomoo_item

  validates :name, presence: true

  scope :active, -> { where(scheduled_for_deletion: false) }
  # IS NULL is the only test an encrypted column supports, so a connection
  # without tokens stores nil, never "".
  scope :connected, -> { where.not(refresh_token: nil) }
  scope :syncable, -> { active.connected }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def connected?
    refresh_token.present?
  end
  alias_method :credentials_configured?, :connected?
  alias_method :oauth_configured?, :connected?

  def needs_authorization?
    !connected? || requires_update?
  end

  # Every sync refreshes the access token, so a stale refresh means syncs have stopped.
  def token_inactive_soon?
    connected? && last_token_refresh_at.present? && last_token_refresh_at < INACTIVITY_WARNING.ago
  end

  def default_name
    I18n.t("moomoo_items.default_name")
  end

  def reauth_reason_message
    I18n.t("moomoo_items.reauth_reasons.#{reauth_reason}", default: nil) if requires_update? && reauth_reason.present?
  end

  # Registers this connection's own OAuth client for redirect_uri unless it
  # already has one for that exact URI. A moved host, or a client moomoo no
  # longer knows (invalid_client), gets a new registration. Only for a
  # connection without tokens: one that a consent completes meanwhile keeps
  # the client its tokens belong to. See #oauth_client_for_consent!.
  def ensure_oauth_client!(redirect_uri:)
    return if oauth_client_registered_for?(redirect_uri)

    registration = register_oauth_client(redirect_uri)
    with_lock do
      raise Provider::Moomoo::MoomooError.new("moomoo connection was completed by another consent", :already_connected) if connected?

      update!(registration_attributes(registration))
    end
  end

  # The id of the client a consent for redirect_uri runs with: the stored one
  # if it is registered for that URI, or else a registration for it kept in
  # pending_oauth_client, made now unless a recent one is pending. A new one
  # keeps the one it replaces under "previous", for the consents still running
  # with it. A pending client replaces the stored one only when a consent with
  # it succeeds: tokens belong to the client that issued them, so an abandoned
  # consent must leave a working connection on its own client.
  def oauth_client_for_consent!(redirect_uri:)
    return oauth_client_id if oauth_client_registered_for?(redirect_uri)

    unless reusable_pending_client?(redirect_uri)
      registration = register_oauth_client(redirect_uri).merge("registered_at" => Time.current.to_i)
      with_lock do
        previous = pending_registrations.first
        update!(pending_oauth_client: previous ? registration.merge("previous" => previous) : registration)
      end
    end
    pending_oauth_client["client_id"]
  end

  def authorization_url(state:, code_challenge:, client_id:)
    redirect_uri, = consent_client(client_id)
    Provider::Moomoo.new(client_id: client_id).authorization_url(redirect_uri: redirect_uri, state: state, code_challenge: code_challenge)
  end

  # Runs inside the callback request: the code is valid once, for five
  # minutes, and only with the client the consent was started with
  # (`client_id`, see #oauth_client_for_consent!), which its tokens belong to.
  # A refused grant stores nothing and leaves the connection as it was, so a
  # working connection keeps syncing. `new_connection` is a consent started by
  # Connect: if another consent completed this connection meanwhile, it is
  # kept rather than replaced.
  def complete_authorization!(code:, code_verifier:, client_id:, new_connection: false)
    redirect_uri, registration = consent_client(client_id)
    tokens = Provider::Moomoo.new(client_id: client_id).exchange_code(code: code, redirect_uri: redirect_uri, code_verifier: code_verifier)
    # Checked before the lock, whose transaction would take a refusal's log entry with it.
    refusal = grant_refusal(tokens[:scope].to_s.split)

    with_lock do
      raise Provider::Moomoo::MoomooError.new("moomoo connection was completed by another consent", :already_connected) if new_connection && connected?
      # The connection may have moved to another client meanwhile.
      unless registration || oauth_client_id == client_id
        raise Provider::Moomoo::MoomooError.new("moomoo connection moved to another client during this consent", :client_replaced)
      end
      raise refusal if refusal

      # The stored refresh token belongs to the stored client.
      new_refresh_token = tokens[:refresh_token] || (refresh_token unless registration)
      raise Provider::Moomoo::MoomooError.new("moomoo returned no refresh token", :token_failed) if new_refresh_token.blank?

      update!(
        **(registration ? registration_attributes(registration).merge(pending_oauth_client: pending_oauth_client_without(client_id)) : {}),
        access_token: tokens[:access_token],
        refresh_token: new_refresh_token,
        access_token_expires_at: tokens[:expires_in].seconds.from_now,
        oauth_scope: tokens[:scope].presence,
        last_authorized_at: Time.current,
        last_token_refresh_at: Time.current,
        status: :good,
        reauth_reason: nil
      )
    end
  end

  # Yields a callable that returns a valid access token (see
  # #fresh_access_token), to call before every request.
  def with_access_token
    raise Provider::Moomoo::MoomooError.new("moomoo connection is not authorized", :not_connected) unless connected?

    @early_refresh_failed = false
    yield method(:fresh_access_token)
  rescue Provider::Moomoo::MoomooError => e
    mark_requires_update!(e.error_type.to_s) if e.reauth_required?
    raise
  ensure
    @early_refresh_failed = false
  end

  # Refreshes under the row lock when the token is about to expire, or when
  # `rejected` is the token a request was just refused with. The lock keeps
  # web and worker processes from refreshing at once, and reloads the row.
  # A transient failure of the early refresh keeps the stored token in use
  # until it expires, without asking moomoo again before then.
  def fresh_access_token(rejected: nil)
    # A sync asks before every request, so a token that is far from expiring
    # and was not refused is used without locking and reloading the item.
    return access_token if rejected.blank? && access_token.present? && access_token_expires_at&.>(TOKEN_REFRESH_BUFFER.from_now)

    with_lock do
      refused = rejected.present? && access_token == rejected
      valid = access_token.present? && access_token_expires_at.present? && access_token_expires_at.future?
      expiring = !valid || access_token_expires_at <= TOKEN_REFRESH_BUFFER.from_now

      if refused || (expiring && !(valid && @early_refresh_failed))
        begin
          refresh_tokens!
        rescue Provider::Moomoo::MoomooError => e
          raise if refused || !valid || e.reauth_required?

          @early_refresh_failed = true
          log_auth("warn", "token refresh failed (#{e.error_type}); using the stored token until it expires", status: e.status)
        end
      end

      access_token
    end
  end

  # Locked and reloaded first: a reconnect that committed since this row's
  # tokens were read replaced the refresh token, and its connection works.
  def mark_requires_update!(reason)
    token_in_use = refresh_token
    flagged = with_lock do
      next false unless refresh_token == token_in_use

      update!(status: :requires_update, reauth_reason: reason)
      true
    end
    log_auth("warn", "connection needs reauthorization (#{reason})") if flagged
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error "MoomooItem #{id} - Failed to flag connection for reauthorization: #{e.message}"
  end

  def import_latest_data
    MoomooItem::Importer.new(self).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "MoomooItem #{id} - Failed to import data: #{e.message}",
      source: "moomoo",
      family: family,
      provider_key: "moomoo",
      metadata: { error_type: e.try(:error_type), code: e.try(:code) }.compact
    )
    raise
  end

  # An account the last sync couldn't refresh is left as it is; see
  # MoomooAccount#snapshot_stale?.
  def process_accounts
    processed = linked_moomoo_accounts.includes(account_provider: :account).each_with_object([]) do |moomoo_account, results|
      account = moomoo_account.current_account
      next if account.nil? || account.pending_deletion? || account.disabled?

      begin
        result = MoomooAccount::Processor.new(moomoo_account).process
        results << { moomoo_account_id: moomoo_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "MoomooItem #{id} - Failed to process account #{moomoo_account.id}: #{e.message}",
          source: "moomoo",
          family: family,
          provider_key: "moomoo",
          account_provider_id: moomoo_account.account_provider&.id
        )
        results << { moomoo_account_id: moomoo_account.id, success: false, error: e.message }
      end
    end

    # A cash account that held its stocks account's trades until that account
    # took them this sync can be made a cash account now, before its balances
    # are worked out (see MoomooAccount::CashAccountConversion).
    linked_moomoo_accounts.where(role: "cash").find_each { |moomoo_account| MoomooAccount::CashAccountConversion.new(moomoo_account).convert }
    processed
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.reject { |account| account.pending_deletion? || account.disabled? }.each_with_object([]) do |account, results|
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
      results << { account_id: account.id, success: true }
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "MoomooItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
        source: "moomoo",
        family: family,
        provider_key: "moomoo",
        account_id: account.id
      )
      results << { account_id: account.id, success: false, error: e.message }
    end
  end

  # Read through the links alone: the rows hold years of encrypted history
  # that pages listing the connection's accounts have no use for.
  def accounts
    links = AccountProvider.where(provider_type: MoomooAccount.name, provider_id: moomoo_accounts.select(:id))
    Account.where(id: links.select(:account_id)).to_a
  end

  def linked_moomoo_accounts
    moomoo_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    linkable_moomoo_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    setup_candidate_moomoo_accounts.count
  end

  # The rows setup offers: those not set up yet, except the rows of a trading
  # account the last import didn't fetch. One the user stopped sharing is
  # kept for its linked rows (see MoomooItem::Importer#prune_unseen_accounts),
  # but its other rows would never update.
  def setup_candidate_moomoo_accounts
    unlinked = linkable_moomoo_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    listed_at = last_accounts_listing_at
    return unlinked unless listed_at

    unseen = moomoo_accounts.primary.where(last_seen_at: ...listed_at).select(:id)
    unlinked.where.not(id: unseen)
      .merge(MoomooAccount.primary.or(MoomooAccount.where.not(primary_moomoo_account_id: unseen)))
  end

  def total_accounts_count
    linkable_moomoo_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("moomoo_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("moomoo_items.sync_status.all_linked", count: linked)
    else
      I18n.t("moomoo_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("providers.moomoo.institution_name")
  end

  # Loads only the columns the check reads (see #accounts).
  def history_backfill_pending?
    fetched_moomoo_accounts.select(:id, :primary_moomoo_account_id, :enable_markets, :history_cursors)
      .any?(&:history_backfill_pending?)
  end

  # The linkable accounts the last import fetched: each account moomoo listed
  # then got that import's last_seen_at. One the user stopped sharing keeps
  # an older one, and is never fetched again.
  def fetched_moomoo_accounts
    listed_at = last_accounts_listing_at
    listed_at ? linkable_moomoo_accounts.primary.where(last_seen_at: listed_at) : linkable_moomoo_accounts.none
  end

  # When the last import listed the trading accounts. Recorded even when
  # moomoo listed none, so an account kept for its links is never taken for
  # a fetched one; a connection not imported since then falls back to the
  # newest listing an account got.
  def last_accounts_listing_at
    accounts_listed_at || moomoo_accounts.primary.maximum(:last_seen_at)
  end

  private

    def refresh_tokens!
      tokens = moomoo_provider.refresh_access_token(refresh_token)
      update!(
        access_token: tokens[:access_token],
        # moomoo does not rotate the refresh token.
        refresh_token: tokens[:refresh_token] || refresh_token,
        access_token_expires_at: tokens[:expires_in].seconds.from_now,
        oauth_scope: tokens[:scope].presence || oauth_scope,
        last_token_refresh_at: Time.current
      )
    end

    def oauth_client_registered_for?(redirect_uri)
      oauth_client_id.present? && oauth_redirect_uri == redirect_uri && reauth_reason != "invalid_client"
    end

    def reusable_pending_client?(redirect_uri)
      pending = pending_oauth_client
      pending.is_a?(Hash) && pending["redirect_uri"] == redirect_uri && pending["registered_at"].to_i > PENDING_CLIENT_REUSE.ago.to_i
    end

    def register_oauth_client(redirect_uri)
      Provider::Moomoo.register_client(redirect_uri: redirect_uri).transform_keys(&:to_s).merge("redirect_uri" => redirect_uri)
    end

    def registration_attributes(registration)
      {
        oauth_client_id: registration["client_id"],
        oauth_redirect_uri: registration["redirect_uri"],
        oauth_registered_scope: registration["scope"],
        oauth_registration_access_token: registration["registration_access_token"],
        oauth_registration_client_uri: registration["registration_client_uri"]
      }
    end

    # The newest pending registration, and the one it replaced if any.
    def pending_registrations
      pending = pending_oauth_client
      return [] unless pending.is_a?(Hash)

      [ pending.except("previous"), pending["previous"] ].select { |registration| registration.is_a?(Hash) && registration["client_id"].present? }
    end

    # What stays pending once the registration of client_id is stored.
    def pending_oauth_client_without(client_id)
      newest, previous = pending_registrations.reject { |registration| registration["client_id"] == client_id }
      newest && previous ? newest.merge("previous" => previous) : newest
    end

    # The redirect URI of the client a consent was started with and, for a
    # pending client, its registration. A consent whose client this connection
    # no longer has can't finish: its code is valid only with that client.
    def consent_client(client_id)
      return [ oauth_redirect_uri, nil ] if client_id.present? && client_id == oauth_client_id

      registration = pending_registrations.find { |candidate| candidate["client_id"] == client_id } if client_id.present?
      raise Provider::Moomoo::MoomooError.new("moomoo consent was started with a client this connection no longer has", :client_replaced) unless registration

      [ registration["redirect_uri"], registration ]
    end

    # Sure needs trade:read and at least one trading account, and refuses a
    # token that can place orders. A token without any scope is accepted: the
    # first sync's requests show whether it works. Returns the error a refused
    # grant is raised with.
    def grant_refusal(scopes)
      if scopes.empty?
        log_auth("warn", "moomoo returned the token without a scope; trade:read is assumed")
        return
      end

      if scopes.include?(Provider::Moomoo::ORDER_SCOPE)
        log_auth("warn", "grant refused: it includes #{Provider::Moomoo::ORDER_SCOPE}")
        return Provider::Moomoo::MoomooError.new("moomoo authorization granted order placing, which Sure does not accept", :write_scope_granted)
      end

      return if scopes.include?(Provider::Moomoo::REQUIRED_SCOPE) && scopes.any? { |scope| scope.start_with?("accid:") }

      log_auth("warn", "grant refused: it lacks trade:read or any trading account", granted: scopes.reject { |scope| scope.start_with?("accid:") })
      Provider::Moomoo::MoomooError.new("moomoo authorization did not grant trade:read for a trading account", :scope_missing)
    end

    def log_auth(level, message, **metadata)
      DebugLogEntry.capture(
        category: "provider_auth",
        level: level,
        message: "MoomooItem #{id} - #{message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: family,
        metadata: metadata
      )
    end
end
