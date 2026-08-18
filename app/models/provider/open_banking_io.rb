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
  #
  # MUST NOT exceed the server's AccountsController.MaxPageSize (500). A larger value is
  # clamped server-side, which makes the short-page terminator below fire on page one and
  # silently import a single page of an N-page statement.
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
    attr_reader :status, :body, :retry_after

    def initialize(status, body, retry_after = nil)
      @status = status
      @body = body
      @retry_after = retry_after
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
    :reference_number_schema,
    :exchange_rate,
    :merchant_category_code,
    # FX: the amount and currency the user actually agreed to, before conversion.
    :instructed_amount,           # BigDecimal or nil
    :instructed_currency,
    :balance_after_transaction,   # BigDecimal or nil
    :balance_after_computed,      # true when the service derived it rather than the bank reporting it
    :balance_after_currency,
    keyword_init: true
  )

  TransactionPage = Struct.new(:items, :total, keyword_init: true)

  # `served_from_date` is the window the bank actually agreed to, which can be later OR
  # earlier than the one requested -- without it a backfill silently under-delivers.
  SyncResult = Struct.new(:new_transactions, :total_fetched, :served_from_date, keyword_init: true)

  # `failures` is per-account: {account_id:, reason:, bank_error_code:}. Dropping it made a
  # partial failure (3 of 5 accounts needing reconnect) read as total success.
  SyncAllResult = Struct.new(:accounts, :new_transactions, :failures, keyword_init: true)

  # -- Zero-knowledge envelope decryption --------------------------------------
  #
  # Scheme: ephemeral ECDH on NIST P-256 -> HKDF-SHA256 -> AES-256-GCM.
  # Wire: version(1)=0x01 | ephemeralPublicKeyRaw(65) | nonce(12) | tag(16) | ciphertext.
  # Only the user's private key can decrypt -- the service stores ciphertext it cannot read.
  module Envelope
    VERSION_BYTE = 0x01
    # SEC1 uncompressed point marker. The hybrid forms (0x06/0x07) decode to the same
    # point and OpenSSL accepts them, but EnvelopeCrypto.ImportPublicPoint and WebCrypto's
    # importKey both reject anything but 0x04 -- so accepting them here would make this
    # reader disagree with the C# and browser readers on the same bytes.
    UNCOMPRESSED_POINT_PREFIX = 0x04
    POINT_LEN = 65
    NONCE_LEN = 12
    TAG_LEN = 16
    HKDF_SALT = ("\x00".b * 32)
    HKDF_INFO = "bank.core.ci/zk/v1".b.freeze
    GROUP = OpenSSL::PKey::EC::Group.new("prime256v1")

    module_function

    # Loads a base64 PKCS#8 EC (P-256) private key.
    #
    # The empty passphrase is deliberate: without it OpenSSL::PKey.read prompts on stdin
    # for an encrypted PEM, which blocks the thread whenever a TTY is attached (bin/dev,
    # rails console, a foreground container).
    def load_private_key(private_key_pkcs8_b64)
      key = OpenSSL::PKey.read(decode_base64(private_key_pkcs8_b64, "private key"), "")
      unless key.is_a?(OpenSSL::PKey::EC)
        raise ArgumentError, "Private key is not an EC key"
      end

      key
    rescue OpenSSL::OpenSSLError
      # Callers rescue ArgumentError; leaking OpenSSL's own class here bypasses the
      # :configuration_error mapping in Provider::OpenBankingIo#initialize. The message is
      # OpenSSL's constant "Could not parse PKey" -- it carries no key material.
      raise ArgumentError, "Private key could not be parsed"
    end

    # Base64.decode64 silently discards invalid characters and tolerates missing padding,
    # which turns "corrupt transport" into a short envelope that fails much later as an
    # opaque GCM error. The service emits standard padded base64, so strict is safe.
    def decode_base64(value, label)
      Base64.strict_decode64(value.to_s)
    rescue ArgumentError
      raise ArgumentError, "Invalid base64 in open-banking.io #{label}"
    end

    # Decrypts raw envelope bytes to plaintext bytes.
    def decrypt(private_key, envelope_bytes)
      min_len = 1 + POINT_LEN + NONCE_LEN + TAG_LEN
      raise ArgumentError, "Envelope too short" if envelope_bytes.bytesize < min_len

      version = envelope_bytes.getbyte(0)
      unless version == VERSION_BYTE
        # v2 (context-bound) envelopes exist in the service but its writer is pinned to v1
        # until every SDK reader supports them -- see open-banking-io/docs/envelope-versioning.md.
        raise ArgumentError, "Unsupported envelope version #{version}"
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
      unless eph_pub_bytes.getbyte(0) == UNCOMPRESSED_POINT_PREFIX
        raise ArgumentError, "Invalid ephemeral public key in envelope: expected an uncompressed point"
      end

      point = OpenSSL::PKey::EC::Point.new(GROUP, OpenSSL::BN.new(eph_pub_bytes, 2))
      # OpenSSL accepts 65 zero bytes as the point at infinity without complaint; only
      # dh_compute_key would object, and it raises PKeyError rather than ArgumentError.
      raise ArgumentError, "Invalid ephemeral public key in envelope: point at infinity" if point.infinity?

      point
    rescue OpenSSL::PKey::EC::Point::Error, OpenSSL::BNError => e
      raise ArgumentError, "Invalid ephemeral public key in envelope: #{e.message}"
    end

    # Decrypts a base64 envelope and parses its JSON payload. nil in -> nil out.
    def decrypt_to_json(private_key, envelope_b64)
      return nil if envelope_b64.nil? || envelope_b64.empty?

      plaintext = decrypt(private_key, decode_base64(envelope_b64, "envelope"))
      begin
        JSON.parse(plaintext)
      rescue JSON::ParserError
        # JSON::ParserError embeds an excerpt of its input, and here the input is decrypted
        # bank data. Never let that reach a log, Sentry, or a DebugLogEntry.
        raise ArgumentError, "Decrypted envelope payload is not valid JSON"
      end
    end
  end

  # -- Server-to-server HTTP client --------------------------------------------
  class Client
    DEFAULT_OPEN_TIMEOUT = 15
    DEFAULT_READ_TIMEOUT = 30
    # POST api/sync fans out to the user's banks synchronously, so it needs far longer than
    # a plain read. Timing out here does not stop the server -- it finishes the sync while
    # we import the pre-sync snapshot, leaving every sync one round stale and invisibly so.
    SYNC_READ_TIMEOUT = 180
    USER_AGENT = "open-banking-io/ruby/#{UPSTREAM_VERSION}".freeze

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError, EOFError,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
      OpenSSL::SSL::SSLError
    ].freeze
    # 429 is worth another attempt; 503 is the service's own "Transient" classification.
    # 502 is NOT here -- the bank answered, and answered no.
    RETRYABLE_STATUSES = [ 429, 503 ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2
    MAX_RETRY_DELAY = 30
    # Above this we surface :rate_limited instead of sleeping. The sync endpoints advertise
    # Retry-After: 21600 (6h) when Enable Banking throttles the whole application -- obeying
    # that literally would pin a Sidekiq worker for a quarter of a day.
    MAX_HONOURED_RETRY_AFTER = 60

    def initialize(api_base_url:, api_key:, private_key_pkcs8:,
                   open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
      raise ArgumentError, "api_base_url is required" if blank?(api_base_url)
      raise ArgumentError, "api_key is required" if blank?(api_key)
      raise ArgumentError, "private_key_pkcs8 is required" if blank?(private_key_pkcs8)

      base = api_base_url.to_s
      base = base.chomp("/") while base.end_with?("/")
      @base_uri = URI.parse(base + "/")
      @api_key = api_key
      @private_key = Envelope.load_private_key(private_key_pkcs8)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @http = nil
    end

    # Releases the keep-alive connection. Callers that finish a sync should call this;
    # the connection is re-established lazily on the next request either way.
    def close
      @http.finish if @http&.started?
    rescue IOError
      # already closed
    ensure
      @http = nil
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

    # Syncs one account: posts its locally-decrypted uid so the service need not store it.
    #
    # `from_date` is the backfill lever. Without it the server only advances its own
    # incremental cursor, so asking for two years of history returns two years of nothing.
    def sync(account_id, from_date: nil)
      account = account_wires.find { |a| a["id"] == account_id }
      raise ArgumentError, "Account #{account_id} not found" if account.nil?

      uid = decrypt_uid(account)
      if uid.nil?
        raise ArgumentError, "Account has no active session (reconnect required) -- cannot sync"
      end

      body = { "uid" => uid }
      body["fromDate"] = from_date.to_s if from_date.present?

      result = post_json("api/accounts/#{account_id}/sync", body, read_timeout: SYNC_READ_TIMEOUT)
      SyncResult.new(
        new_transactions: result["newTransactions"] || 0,
        total_fetched: result["totalFetched"] || 0,
        served_from_date: result["servedFromDate"]
      )
    end

    # Triggers an online sync of every account that has an active session.
    def sync_all
      items = []
      account_wires.each do |a|
        uid = decrypt_uid(a)
        items << { "accountId" => a["id"], "uid" => uid } unless uid.nil?
      end

      result = post_json("api/sync", { "items" => items }, read_timeout: SYNC_READ_TIMEOUT)
      SyncAllResult.new(
        accounts: result["accounts"] || 0,
        new_transactions: result["newTransactions"] || 0,
        failures: Array(result["failures"]).map do |failure|
          {
            account_id: failure["accountId"],
            reason: failure["reason"],
            bank_error_code: failure["bankErrorCode"]
          }
        end
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
          reference_number_schema: d["referenceNumberSchema"],
          exchange_rate: d["exchangeRate"],
          merchant_category_code: d["merchantCategoryCode"],
          instructed_amount: parse_decimal_nullable(d["instructedAmount"]),
          instructed_currency: d["instructedCurrency"],
          balance_after_transaction: parse_decimal_nullable(d["balanceAfter"]),
          balance_after_computed: d["balanceAfterComputed"] == "true",
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

      def post_json(path, body, read_timeout: nil)
        uri = resolve(path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        send_request(uri, request, read_timeout: read_timeout)
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
      def send_request(uri, request, read_timeout: nil)
        raise ArgumentError, "open-banking.io requires https" unless uri.scheme == "https"

        request["X-Api-Key"] = @api_key
        request["Accept"] = "application/json"
        request["User-Agent"] = USER_AGENT

        attempt = 0
        begin
          attempt += 1
          response = http_for(uri, read_timeout: read_timeout).request(request)
          code = response.code.to_i
          unless code.between?(200, 299)
            raise HTTPError.new(code, response.body, positive_integer(response["Retry-After"]))
          end

          body = response.body
          return nil if body.nil? || body.empty?

          JSON.parse(body)
        rescue *RETRYABLE_ERRORS, HTTPError => e
          raise unless retryable?(e)
          raise if attempt > MAX_RETRIES

          delay = retry_delay(e, attempt)
          raise if delay.nil?

          # A socket error may have killed the keep-alive connection; retrying on the dead
          # one just fails again.
          close unless e.is_a?(HTTPError)

          Rails.logger.warn(
            "open-banking.io: request failed (attempt #{attempt}/#{MAX_RETRIES}): " \
            "#{e.class}#{e.is_a?(HTTPError) ? " HTTP #{e.status}" : ""}. Retrying in #{delay.round(1)}s"
          )
          sleep(delay)
          retry
        end
      end

      def retryable?(error)
        return true unless error.is_a?(HTTPError)

        RETRYABLE_STATUSES.include?(error.status)
      end

      # A server-advertised Retry-After wins over our own curve. nil means "do not retry".
      def retry_delay(error, attempt)
        if error.is_a?(HTTPError) && error.retry_after
          return nil if error.retry_after > MAX_HONOURED_RETRY_AFTER

          # Jitter so a family's accounts do not all resume in lockstep and re-trip the
          # per-API-key window.
          return error.retry_after + (error.retry_after * rand * 0.25)
        end

        base = INITIAL_RETRY_DELAY * (2**(attempt - 1))
        [ base + (base * rand * 0.25), MAX_RETRY_DELAY ].min
      end

      def positive_integer(value)
        parsed = value.to_i
        parsed.positive? ? parsed : nil
      end

      # One keep-alive connection per client. The host is fixed at construction, so a
      # single pooled connection is always the right one -- and a long backfill would
      # otherwise pay a TLS handshake per page.
      def http_for(uri, read_timeout: nil)
        if @http && @http.started? && (@http.address != uri.host || @http.port != uri.port)
          close
        end

        @http ||= begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = @open_timeout
          http.keep_alive_timeout = 30
          http.start
          http
        end

        @http.read_timeout = read_timeout || @read_timeout
        @http
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
  rescue ArgumentError, OpenSSL::OpenSSLError => e
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
      total = nil
      truncated = true

      MAX_PAGES.times do
        page = @client.get_transactions(account_id, from: from, to: to, limit: PAGE_LIMIT, offset: offset)
        items = Array(page.items)
        total ||= page.total.to_i
        results.concat(items.map { |txn| transaction_hash(txn) })

        if items.size < PAGE_LIMIT || (total.positive? && results.size >= total)
          truncated = false
          break
        end

        offset += PAGE_LIMIT
      end

      if truncated
        # Returning a short array would be indistinguishable from a bank that simply has
        # fewer rows -- and the importer would then treat the missing rows as gone.
        raise Error.new(
          "open-banking.io pagination cap reached for account #{account_id}: " \
          "fetched #{results.size} of #{total} rows (MAX_PAGES=#{MAX_PAGES})",
          :pagination_truncated
        )
      end

      results
    end
  end

  private

    def with_error_handling(operation)
      yield
    rescue HTTPError => e
      raise Error.new(
        "open-banking.io request failed (#{operation}): HTTP #{e.status}#{problem_detail(e.body)}",
        error_type_for_status(e.status)
      )
    rescue Error
      raise
    rescue => e
      raise Error.new("open-banking.io request failed (#{operation}): #{e.class}: #{e.message}", :request_failed)
    end

    # The ProblemDetails body carries `reason` (reconnect_needed / rate_limited / bank_error
    # / consent_withdrawn / transient), an optional `bankErrorCode`, and `traceId` -- the only
    # handle linking a user's report to the server's sync_attempt_log row. Allow-listed and
    # bounded, because `detail` is unvalidated prose forwarded from the bank.
    def problem_detail(body)
      return "" if body.blank?

      parsed = JSON.parse(body)
      return "" unless parsed.is_a?(Hash)

      bits = parsed.values_at("reason", "bankErrorCode", "traceId").compact
      bits.any? ? " (#{bits.join(' ')})" : ""
    rescue JSON::ParserError
      ""
    end

    def error_type_for_status(status)
      case status.to_i
      when 401 then :unauthorized
      when 402 then :payment_required     # NotEntitledException: trial ended / zero balance
      when 403 then :access_forbidden
      when 404 then :not_found
      when 409 then :requires_reconnect   # consent_withdrawn / reconnect_needed
      when 429 then :rate_limited
      when 502 then :bank_error           # the bank answered, and answered no -- not retriable
      when 503 then :server_error         # the service's own "Transient" classification
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
        creditor_iban: txn.creditor_iban,
        creditor_bban: txn.creditor_bban,
        creditor_agent_bic: txn.creditor_agent_bic,
        debtor_name: txn.debtor_name,
        debtor_iban: txn.debtor_iban,
        debtor_bban: txn.debtor_bban,
        debtor_agent_bic: txn.debtor_agent_bic,
        remittance_information: txn.remittance_information,
        note: txn.note,
        reference_number: txn.reference_number,
        reference_number_schema: txn.reference_number_schema,
        exchange_rate: txn.exchange_rate,
        merchant_category_code: txn.merchant_category_code,
        instructed_amount: decimal_string(txn.instructed_amount),
        instructed_currency: txn.instructed_currency,
        balance_after_transaction: decimal_string(txn.balance_after_transaction),
        balance_after_computed: txn.balance_after_computed,
        balance_after_currency: txn.balance_after_currency
      }
    end

    # Parse-or-raise. Returning nil for an unexpected shape would be silent corruption:
    # OpenBankingIoEntry::Processor#amount turns a nil amount into a zero-amount
    # transaction rather than failing.
    def decimal_string(value)
      return nil if value.nil?
      return value.to_s("F") if value.is_a?(BigDecimal)

      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError, TypeError
      raise Error.new("open-banking.io returned an unparseable decimal (#{value.class})", :invalid_response)
    end
end
