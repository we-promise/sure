class Provider::Truelayer::Adapter
  extend Provider::ConnectionAdapter

  def self.display_name = "TrueLayer"
  def self.description = "UK & European bank connections via open banking."
  def self.brand_color = "#00D64A"
  def self.beta? = true

  # TrueLayer requires per-family BYOK credentials (each family enters their
  # own client_id/secret in provider_family_configs).
  def self.requires_family_config? = true

  # TrueLayer Console exposes a "sandbox" flag stored on FamilyConfig.credentials.
  # OauthCallbacksController calls this to thread it through authorize_url.
  def self.sandbox_for(config)
    return false unless config.credentials.is_a?(Hash)
    !!(config.credentials["sandbox"] || config.credentials[:sandbox])
  end

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def self.syncer_class = Provider::Truelayer::Syncer

  def self.auth_class = Provider::Auth::OAuth2

  def self.reauth_url(connection, redirect_uri:, state:)
    config = connection.provider_family_config
    Provider::Truelayer.reauth_uri(
      refresh_token: connection.credentials["refresh_token"],
      redirect_uri:  redirect_uri,
      state:         state,
      client_id:     config.client_id,
      client_secret: config.client_secret,
      sandbox:       connection.metadata["sandbox"]
    )
  end

  def self.connection_configs(family:)
    [ {
      key:  "truelayer",
      name: display_name,
      new_account_path: ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.select_provider_connections_path(provider_key: "truelayer")
      },
      existing_account_path: nil
    } ]
  end

  ACCOUNTABLE_MAP = {
    "depository" => Depository,
    "credit"     => CreditCard
  }.freeze

  def self.build_sure_account(provider_account, family:)
    accountable_class = ACCOUNTABLE_MAP[provider_account.external_type.to_s] ||
      raise(Provider::Account::UnsupportedAccountableType,
            "Truelayer::Adapter does not handle external_type=#{provider_account.external_type.inspect}")
    accountable = accountable_class.new(subtype: provider_account.external_subtype)
    family.accounts.build(
      name:        provider_account.external_name,
      currency:    provider_account.currency,
      balance:     0,
      accountable: accountable
    )
  end

  ACCOUNT_TYPE_MAP = {
    "TRANSACTION"          => "depository",
    "SAVINGS"              => "depository",
    "BUSINESS_TRANSACTION" => "depository",
    "BUSINESS_SAVINGS"     => "depository"
  }.freeze

  ACCOUNT_SUBTYPE_MAP = {
    "TRANSACTION"          => "checking",
    "SAVINGS"              => "savings",
    "BUSINESS_TRANSACTION" => "checking",
    "BUSINESS_SAVINGS"     => "savings"
  }.freeze

  def initialize(connection)
    @connection = connection
  end

  # Called by Provider::ConnectionRegistry.config_for("truelayer")
  # These stateless methods (authorize_url, scopes, token_client, fetch_consent_expiry) are
  # invoked with connection=nil, so they must not touch @connection.

  def authorize_url(client_id:, redirect_uri:, state:, scope:, sandbox: false)
    auth_base = sandbox ? Provider::Truelayer::SANDBOX_AUTH : Provider::Truelayer::PRODUCTION_AUTH
    params = {
      response_type: "code",
      client_id:     client_id,
      scope:         Array(scope).join(" "),
      redirect_uri:  redirect_uri,
      state:         state,
      providers:     sandbox ? "mock" : "uk-ob-all uk-oauth-all ie-ob-all"
    }
    "#{auth_base}/?#{params.to_query}"
  end

  def scopes
    %w[info accounts balance transactions cards offline_access]
  end

  def token_client(credentials, sandbox: false)
    Provider::Truelayer.token_client(credentials, sandbox: sandbox)
  end

  def fetch_consent_expiry(connection, access_token)
    response = Provider::Truelayer.new(access_token, sandbox: connection.metadata["sandbox"]).me
    raw = response.dig("results", 0, "consent_expires_at")
    Time.parse(raw) if raw
  rescue
    nil
  end

  # Data-fetching methods — called by Truelayer::Syncer with a real connection.
  #
  # Returns { accounts: [...], partial: false }. If either the /accounts or
  # /cards endpoint errors transiently, we return what we got plus
  # `partial: true` so the syncer knows NOT to flip everything-not-in-this-set
  # to "disappeared" (transient failure ≠ user closed every account).
  # The other call sites (transaction sync) get the same flat array shape via
  # `fetch_accounts(token)[:accounts]`.
  def fetch_accounts(token)
    c = client(token)
    partial = false
    accounts = begin
      c.get_accounts.map { |a| normalise_account(a, kind: "account") }
    rescue Provider::Truelayer::Error => e
      Rails.logger.warn("[Truelayer::Adapter] /accounts errored: #{e.class}: #{e.message}")
      partial = true
      []
    end
    cards = begin
      c.get_cards.map { |a| normalise_account(a, kind: "card") }
    rescue Provider::Truelayer::Error => e
      Rails.logger.warn("[Truelayer::Adapter] /cards errored: #{e.class}: #{e.message}")
      partial = true
      []
    end
    { accounts: accounts + cards, partial: partial }
  end

  def fetch_balance(token, provider_account)
    kind = provider_account.external_type == "credit" ? "card" : "account"
    client(token).get_balance(provider_account.external_id, kind: kind)
  end

  def fetch_transactions(token, provider_account, from: 90.days.ago, to: Time.current)
    kind    = provider_account.external_type == "credit" ? "card" : "account"
    c       = client(token)
    settled = c.get_transactions(provider_account.external_id, kind: kind, from: from, to: to)
    pending = c.get_pending_transactions(provider_account.external_id, kind: kind)
    normalise_transactions(settled, pending: false) + normalise_transactions(pending, pending: true)
  end

  private

    def client(token)
      Provider::Truelayer.new(
        token,
        psu_ip:  @connection.metadata["psu_ip"],
        sandbox: @connection.metadata["sandbox"]
      )
    end

    def normalise_account(raw, kind:)
      account_type = raw["account_type"] || raw["card_type"] || ""
      {
        external_id:  raw["account_id"], # TrueLayer uses "account_id" for both bank accounts and cards
        name:         raw["display_name"] || raw["card_type"],
        type:         kind == "card" ? "credit" : ACCOUNT_TYPE_MAP.fetch(account_type, "depository"),
        subtype:      kind == "card" ? "credit_card" : ACCOUNT_SUBTYPE_MAP.fetch(account_type, "checking"),
        currency:     raw["currency"],
        raw_payload:  raw
      }
    end

    def normalise_transactions(raw_list, pending:)
      raw_list.map do |t|
        {
          external_id:                        t["transaction_id"],
          date:                               Date.parse(t["timestamp"]),
          amount:                             BigDecimal(t["amount"].to_s),
          currency:                           t["currency"],
          name:                               extract_name(t),
          merchant_name:                      extract_merchant_name(t),
          notes:                              t["description"].presence,
          pending:                            pending,
          transaction_category:               t["transaction_category"],
          transaction_classification:         t["transaction_classification"],
          normalised_provider_transaction_id: t["normalised_provider_transaction_id"],
          meta:                               t["meta"].presence,
          raw:                                t
        }
      end
    end

    def extract_name(t)
      t["merchant_name"].presence ||
        meta_counterparty_name(t["meta"]) ||
        category_fallback_name(t["transaction_category"]) ||
        humanized_description(t["description"]) ||
        "TrueLayer Transaction"
    end

    def extract_merchant_name(t)
      t["merchant_name"].presence || meta_counterparty_name(t["meta"])
    end

    def meta_counterparty_name(meta)
      return nil unless meta.is_a?(Hash)

      meta["counter_party_preferred_name"].presence ||
        meta["counterparty_name"].presence ||
        meta["party_name"].presence ||
        meta["creditor_name"].presence ||
        meta["debtor_name"].presence
    end

    def category_fallback_name(category)
      case category.to_s.upcase
      when "TRANSFER"       then "Bank Transfer"
      when "ATM"            then "ATM Withdrawal"
      when "DIRECT_DEBIT"   then "Direct Debit"
      when "DIRECT_CREDIT"  then "Direct Credit"
      when "STANDING_ORDER" then "Standing Order"
      when "REPEAT_PAYMENT" then "Repeat Payment"
      when "INTEREST"       then "Interest"
      when "DIVIDEND"       then "Dividend"
      when "FEE"            then "Fee"
      when "CASH"           then "Cash"
      when "CHECK"          then "Cheque"
      end
    end

    # Rejects bare reference codes (e.g. "R2391", "FP12345678") so they don't pollute the name field.
    def humanized_description(desc)
      return nil if desc.blank?
      return nil if desc.match?(/\A[A-Z]{1,4}[\-_]?\d{2,}\z/i)
      desc
    end
end

Provider::ConnectionRegistry.register("truelayer", Provider::Truelayer::Adapter)
