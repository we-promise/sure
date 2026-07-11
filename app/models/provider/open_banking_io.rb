require "net/http"
require "uri"
require "json"
require "openssl"
require "base64"
require "bigdecimal"

# open-banking.io client, inlined from the upstream gem so its HTTP boundary and
# zero-knowledge decryption are reviewable in-tree rather than in a dependency. Derived
# from https://github.com/open-banking-io/clients (ruby/, v0.2.1); only namespacing and
# house style changed -- re-derive from there to update.
#
# `Client` decrypts the service's zero-knowledge envelopes locally with the user's
# private key; this outer class normalises its Structs into JSONB-friendly hashes.
class Provider::OpenBankingIo
  UPSTREAM_VERSION = "0.2.1"

  # Default page size when paginating an account's statement.
  PAGE_LIMIT = 500
  # Safety cap so a misbehaving API can never loop forever.
  MAX_PAGES = 200

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  # Raised when the API returns a non-success HTTP status.
  class HTTPError < StandardError
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      super("open-banking.io request failed with HTTP #{status}")
    end
  end

  # -- Decrypted value objects (amounts BigDecimal, dates ISO-8601 strings) ----
  # `Balance#type` is the ISO 20022 code (ITBD booked, ITAV available, ...).
  Balance = Struct.new(
    :type,
    :name,
    :amount,          # BigDecimal
    :currency,
    :reference_date,
    keyword_init: true
  )

  Account = Struct.new(
    :id,
    :aspsp_name,
    :aspsp_country,
    :currency,
    :account_type,
    :bic,
    :needs_reconnect,
    :iban,
    :bban,
    :owner_name,
    :account_name,
    :product,
    :display_name,
    :balances,        # Array<Balance>
    keyword_init: true
  )

  Transaction = Struct.new(
    :id,
    :currency,
    :credit_debit_indicator,
    :status,
    :booking_date,
    :value_date,
    :transaction_date,
    :bank_transaction_code,
    :amount,          # BigDecimal
    :creditor_name,
    :creditor_iban,
    :creditor_bban,
    :creditor_agent_bic,
    :debtor_name,
    :debtor_iban,
    :debtor_bban,
    :debtor_agent_bic,
    :remittance_information,
    :note,
    :reference_number,
    :exchange_rate,
    :merchant_category_code,
    :balance_after_transaction,   # BigDecimal or nil
    :balance_after_currency,
    keyword_init: true
  )

  TransactionPage = Struct.new(:items, :total, keyword_init: true)

  SyncResult = Struct.new(:new_transactions, :total_fetched, keyword_init: true)

  SyncAllResult = Struct.new(:accounts, :new_transactions, keyword_init: true)

  # -- Zero-knowledge envelope decryption --------------------------------------
  #
  # Scheme: ephemeral ECDH on NIST P-256 -> HKDF-SHA256 -> AES-256-GCM.
  # Wire: version(1)=0x01 | ephemeralPublicKeyRaw(65) | nonce(12) | tag(16) | ciphertext.
  # Only the user's private key can decrypt -- the service stores ciphertext it cannot read.
  module Envelope
    VERSION_BYTE = 0x01
    POINT_LEN = 65
    NONCE_LEN = 12
    TAG_LEN = 16
    HKDF_SALT = ("\x00".b * 32)
    HKDF_INFO = "bank.core.ci/zk/v1".b.freeze
    GROUP = OpenSSL::PKey::EC::Group.new("prime256v1")

    module_function

    # Loads a base64 PKCS#8 EC (P-256) private key.
    def load_private_key(private_key_pkcs8_b64)
      key = OpenSSL::PKey.read(Base64.decode64(private_key_pkcs8_b64))
      unless key.is_a?(OpenSSL::PKey::EC)
        raise ArgumentError, "Private key is not an EC key"
      end

      key
    end

    # Decrypts raw envelope bytes to plaintext bytes.
    def decrypt(private_key, envelope_bytes)
      min_len = 1 + POINT_LEN + NONCE_LEN + TAG_LEN
      if envelope_bytes.bytesize < min_len || envelope_bytes.getbyte(0) != VERSION_BYTE
        raise ArgumentError, "Invalid or unsupported envelope"
      end

      eph_pub_bytes = envelope_bytes.byteslice(1, POINT_LEN)
      nonce = envelope_bytes.byteslice(1 + POINT_LEN, NONCE_LEN)
      tag = envelope_bytes.byteslice(1 + POINT_LEN + NONCE_LEN, TAG_LEN)
      ciphertext = envelope_bytes.byteslice((1 + POINT_LEN + NONCE_LEN + TAG_LEN)..) || "".b

      pub = decode_public_point(eph_pub_bytes)
      shared = private_key.dh_compute_key(pub)

      key = OpenSSL::KDF.hkdf(
        shared,
        salt: HKDF_SALT,
        info: HKDF_INFO,
        length: 32,
        hash: "SHA256"
      )

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = key
      cipher.iv = nonce
      cipher.auth_tag = tag
      cipher.auth_data = "" # no associated data -- matches the server envelope format
      cipher.update(ciphertext) + cipher.final
    end

    # Parses the 65-byte raw ephemeral public key into a P-256 point, wrapping OpenSSL's
    # off-curve/malformed errors in a clean `ArgumentError`.
    def decode_public_point(eph_pub_bytes)
      OpenSSL::PKey::EC::Point.new(GROUP, OpenSSL::BN.new(eph_pub_bytes, 2))
    rescue OpenSSL::PKey::EC::Point::Error, OpenSSL::BNError => e
      raise ArgumentError, "Invalid ephemeral public key in envelope: #{e.message}"
    end

    # Decrypts a base64 envelope and parses its JSON payload. nil in -> nil out.
    def decrypt_to_json(private_key, envelope_b64)
      return nil if envelope_b64.nil?

      plaintext = decrypt(private_key, Base64.decode64(envelope_b64))
      JSON.parse(plaintext)
    end
  end

  # -- Server-to-server HTTP client --------------------------------------------
  class Client
    DEFAULT_OPEN_TIMEOUT = 15
    DEFAULT_READ_TIMEOUT = 60
    USER_AGENT = "open-banking-io/ruby/#{UPSTREAM_VERSION}".freeze

    def initialize(api_base_url:, api_key:, private_key_pkcs8:)
      raise ArgumentError, "api_base_url is required" if blank?(api_base_url)
      raise ArgumentError, "api_key is required" if blank?(api_key)
      raise ArgumentError, "private_key_pkcs8 is required" if blank?(private_key_pkcs8)

      @base_uri = URI.parse(api_base_url.to_s.sub(%r{/+\z}, "") + "/")
      @api_key = api_key
      @private_key = Envelope.load_private_key(private_key_pkcs8)
    end

    def get_accounts
      account_wires.map { |w| map_account(w) }
    end

    # Returns a page of an account's statement, newest first.
    def get_transactions(account_id, from: nil, to: nil, limit: nil, offset: nil)
      params = {}
      params["from"] = from unless from.nil?
      params["to"] = to unless to.nil?
      params["limit"] = limit unless limit.nil?
      params["offset"] = offset unless offset.nil?

      page = get_json("api/accounts/#{account_id}/transactions", params)
      items = (page["items"] || []).map { |t| map_transaction(t) }
      TransactionPage.new(items: items, total: page["total"] || 0)
    end

    # Syncs one account: posts its locally-decrypted uid so the service never holds it plaintext.
    def sync(account_id)
      account = account_wires.find { |a| a["id"] == account_id }
      raise ArgumentError, "Account #{account_id} not found" if account.nil?

      uid = decrypt_uid(account)
      if uid.nil?
        raise ArgumentError, "Account has no active session (reconnect required) -- cannot sync"
      end

      result = post_json("api/accounts/#{account_id}/sync", { "uid" => uid })
      SyncResult.new(
        new_transactions: result["newTransactions"] || 0,
        total_fetched: result["totalFetched"] || 0
      )
    end

    # Triggers an online sync of every account that has an active session.
    def sync_all
      items = []
      account_wires.each do |a|
        uid = decrypt_uid(a)
        items << { "accountId" => a["id"], "uid" => uid } unless uid.nil?
      end

      result = post_json("api/sync", { "items" => items })
      SyncAllResult.new(
        accounts: result["accounts"] || 0,
        new_transactions: result["newTransactions"] || 0
      )
    end

    private

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def account_wires
        get_json("api/accounts")
      end

      def decrypt_uid(account)
        payload = Envelope.decrypt_to_json(@private_key, account["uidEnc"])
        payload && payload["uid"]
      end

      def map_account(a)
        acc = Envelope.decrypt_to_json(@private_key, a["enc"]) || {}
        name = Envelope.decrypt_to_json(@private_key, a["displayNameEnc"]) || {}

        balances = (a["balances"] || []).map do |b|
          dec = Envelope.decrypt_to_json(@private_key, b["enc"]) || {}
          Balance.new(
            type: b["type"] || "",
            currency: b["currency"] || "",
            reference_date: b["referenceDate"],
            name: dec["name"],
            amount: parse_decimal(dec["amount"])
          )
        end

        Account.new(
          id: a["id"] || "",
          aspsp_name: a["aspspName"] || "",
          aspsp_country: a["aspspCountry"] || "",
          currency: a["currency"] || "",
          account_type: a["accountType"],
          bic: a["bic"],
          needs_reconnect: a["needsReconnect"] || false,
          iban: acc["iban"],
          bban: acc["bban"],
          owner_name: acc["ownerName"],
          account_name: acc["accountName"],
          product: acc["product"],
          display_name: name["displayName"],
          balances: balances
        )
      end

      def map_transaction(t)
        d = Envelope.decrypt_to_json(@private_key, t["enc"]) || {}
        Transaction.new(
          id: t["id"] || "",
          currency: t["currency"] || "",
          credit_debit_indicator: t["creditDebitIndicator"] || "",
          status: t["status"],
          booking_date: t["bookingDate"],
          value_date: t["valueDate"],
          transaction_date: t["transactionDate"],
          bank_transaction_code: t["bankTransactionCode"],
          amount: parse_decimal(d["amount"]),
          creditor_name: d["creditorName"],
          creditor_iban: d["creditorIban"],
          creditor_bban: d["creditorBban"],
          creditor_agent_bic: d["creditorAgentBic"],
          debtor_name: d["debtorName"],
          debtor_iban: d["debtorIban"],
          debtor_bban: d["debtorBban"],
          debtor_agent_bic: d["debtorAgentBic"],
          remittance_information: d["remittanceInformation"],
          note: d["note"],
          reference_number: d["referenceNumber"],
          exchange_rate: d["exchangeRate"],
          merchant_category_code: d["merchantCategoryCode"],
          balance_after_transaction: parse_decimal_nullable(d["balanceAfter"]),
          balance_after_currency: d["balanceAfterCurrency"]
        )
      end

      def parse_decimal(value)
        return BigDecimal(0) if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      def parse_decimal_nullable(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      # -- HTTP ----------------------------------------------------------------

      def get_json(path, params = {})
        uri = resolve(path)
        unless params.empty?
          uri.query = URI.encode_www_form(params)
        end

        request = Net::HTTP::Get.new(uri)
        send_request(uri, request)
      end

      def post_json(path, body)
        uri = resolve(path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        send_request(uri, request)
      end

      # `path` is a library-controlled route joined onto the base URI; a relative
      # reference can't change the pinned host or scheme (see send_request).
      def resolve(path)
        (@base_uri + path.sub(%r{\A/+}, "")).dup
      end

      # SSRF: the host is `api_base_url`, pinned to https://<open-banking.io> before this
      # client is built (OpenBankingIoItem.allowed_api_base_url?, enforced by model
      # validation and the controller). No redirects are followed -- a 3xx hits the
      # HTTPError raise below rather than being chased to another host.
      def send_request(uri, request)
        request["X-Api-Key"] = @api_key
        request["Accept"] = "application/json"
        request["User-Agent"] = USER_AGENT

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = DEFAULT_OPEN_TIMEOUT
        http.read_timeout = DEFAULT_READ_TIMEOUT

        response = http.request(request)
        code = response.code.to_i
        raise HTTPError.new(code, response.body) unless code.between?(200, 299)

        body = response.body
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      end
  end

  # -- Provider wrapper --------------------------------------------------------

  attr_reader :api_base_url

  def initialize(api_base_url:, api_key:, private_key:)
    @api_base_url = api_base_url.to_s.strip

    @client = Client.new(
      api_base_url: api_base_url,
      api_key: api_key,
      private_key_pkcs8: private_key
    )
  rescue ArgumentError => e
    raise Error.new(e.message, :configuration_error)
  end

  def get_accounts
    with_error_handling("get_accounts") do
      @client.get_accounts.map { |account| account_hash(account) }
    end
  end

  # Pull fresh data from every connected bank with a live session, so a later
  # get_accounts/get_transactions reads refreshed rather than cached data.
  # Expired-session accounts are skipped upstream (never raises for them).
  def sync_all
    with_error_handling("sync_all") do
      @client.sync_all
    end
  end

  # Refresh a single account. Raises upstream if it has no active session, so
  # best-effort callers should rescue.
  def sync(account_id)
    with_error_handling("sync") do
      @client.sync(account_id)
    end
  end

  def get_account_transactions(account_id:, start_date: nil, end_date: nil)
    with_error_handling("get_account_transactions") do
      from = format_date(start_date)
      to = format_date(end_date)

      results = []
      offset = 0
      MAX_PAGES.times do
        page = @client.get_transactions(account_id, from: from, to: to, limit: PAGE_LIMIT, offset: offset)
        items = Array(page.items)
        results.concat(items.map { |txn| transaction_hash(txn) })

        break if items.size < PAGE_LIMIT
        break if page.total.to_i.positive? && results.size >= page.total.to_i

        offset += PAGE_LIMIT
      end

      results
    end
  end

  private

    def with_error_handling(operation)
      yield
    rescue HTTPError => e
      raise Error.new("open-banking.io request failed (#{operation}): HTTP #{e.status}", error_type_for_status(e.status))
    rescue Error
      raise
    rescue => e
      raise Error.new("open-banking.io request failed (#{operation}): #{e.class}", :request_failed)
    end

    def error_type_for_status(status)
      case status.to_i
      when 401 then :unauthorized
      when 403 then :access_forbidden
      when 404 then :not_found
      when 429 then :rate_limited
      when 500..599 then :server_error
      else :fetch_failed
      end
    end

    def format_date(value)
      return nil if value.nil?
      return value.to_date.iso8601 if value.respond_to?(:to_date)

      value.to_s
    end

    def account_hash(account)
      {
        id: account.id,
        aspsp_name: account.aspsp_name,
        aspsp_country: account.aspsp_country,
        currency: account.currency,
        account_type: account.account_type,
        bic: account.bic,
        needs_reconnect: account.needs_reconnect,
        iban: account.iban,
        bban: account.bban,
        owner_name: account.owner_name,
        account_name: account.account_name,
        product: account.product,
        display_name: account.display_name,
        balances: Array(account.balances).map { |balance| balance_hash(balance) }
      }
    end

    def balance_hash(balance)
      {
        type: balance.type,
        name: balance.name,
        amount: decimal_string(balance.amount),
        currency: balance.currency,
        reference_date: balance.reference_date
      }
    end

    def transaction_hash(txn)
      {
        id: txn.id,
        currency: txn.currency,
        credit_debit_indicator: txn.credit_debit_indicator,
        status: txn.status,
        booking_date: txn.booking_date,
        value_date: txn.value_date,
        transaction_date: txn.transaction_date,
        bank_transaction_code: txn.bank_transaction_code,
        amount: decimal_string(txn.amount),
        creditor_name: txn.creditor_name,
        debtor_name: txn.debtor_name,
        remittance_information: txn.remittance_information,
        note: txn.note,
        reference_number: txn.reference_number,
        merchant_category_code: txn.merchant_category_code,
        balance_after_transaction: decimal_string(txn.balance_after_transaction),
        balance_after_currency: txn.balance_after_currency
      }
    end

    def decimal_string(value)
      return nil if value.nil?

      value.to_s("F") if value.is_a?(BigDecimal)
    end
end
