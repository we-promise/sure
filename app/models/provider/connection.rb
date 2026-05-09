class Provider::Connection < ApplicationRecord
  include Encryptable, Syncable

  self.table_name = "provider_connections"

  belongs_to :family
  belongs_to :provider_family_config, class_name: "Provider::FamilyConfig", optional: true
  has_many :provider_accounts, foreign_key: :provider_connection_id,
                                class_name: "Provider::Account", dependent: :destroy

  if encryption_ready?
    encrypts :credentials
  end

  # Connections only exist when credentials are real — auth flows persist their
  # cross-request state in session (see OauthCallbacksController and
  # EmbeddedLinkCallbacksController), not in a pending DB row.
  enum :status, { healthy: "healthy", requires_update: "requires_update", disconnected: "disconnected" }

  scope :syncable, -> { healthy.or(requires_update) }

  # Known auth backends. Each Provider::Auth::* class corresponds to one entry.
  # Adding a new auth protocol means adding a class under Provider::Auth and
  # extending this list. Defense in depth — adapter contracts already enforce
  # auth_class selection, but a typo or stale row shouldn't be silently accepted.
  AUTH_TYPES = %w[oauth2 embedded_link].freeze

  validates :provider_key, :auth_type, presence: true
  validates :auth_type, inclusion: { in: AUTH_TYPES }, if: :auth_type?

  # Memoized — these read once per connection per render and prefer the
  # already-loaded association (see _connection_provider_panel.html.erb's
  # .includes(:provider_accounts)) over re-issuing LIMIT 1 queries.
  def institution_name
    @institution_name ||= first_provider_account&.raw_payload&.dig("provider", "display_name")&.titleize.presence ||
      provider_key.titleize
  end

  def logo_uri
    return @logo_uri if defined?(@logo_uri)
    @logo_uri = first_provider_account&.safe_logo_uri
  end

  def pending_setup?
    return @pending_setup if defined?(@pending_setup)
    @pending_setup = if provider_accounts.loaded?
      provider_accounts.any? { |pa| pa.account_id.nil? && !pa.skipped? }
    else
      provider_accounts.unlinked_and_unskipped.exists?
    end
  end

  # Adapter syncer protocol contract: every adapter's syncer class MUST
  # implement #discover_accounts_only — fetch the upstream account list and
  # upsert provider_accounts rows, without syncing transactions or balances.
  # Called after auth credentials are first stored.
  def discover_accounts!
    syncer.discover_accounts_only
  end

  # Polymorphic auth backend dispatch. The adapter declares which auth class
  # handles its credential lifecycle: Provider::Auth::OAuth2 for OAuth providers
  # (TrueLayer, Mercury, etc.), Provider::Auth::EmbeddedLink for Plaid-Link-style
  # providers (Plaid, MX, Yodlee). The auth class accepts (connection) on init.
  def auth
    Provider::ConnectionRegistry.adapter_for(provider_key).auth_class.new(self)
  end

  private

    def first_provider_account
      return @first_provider_account if defined?(@first_provider_account)
      @first_provider_account = provider_accounts.loaded? ? provider_accounts.first : provider_accounts.first
    end

    # Overrides Syncable's default `self.class::Syncer.new(self)` dispatch.
    # Provider::Connection is shared across providers, so we dispatch by provider_key
    # via the registry rather than a hardcoded case statement.
    def syncer
      Provider::ConnectionRegistry.syncer_class_for(provider_key).new(self)
    end

    def sync_broadcaster
      Provider::Connection::SyncCompleteEvent.new(self)
    end
end
