require "open_banking_io"

# Thin wrapper around the `open-banking-io` gem.
#
# The gem's Client authenticates with an API key and decrypts the zero-knowledge
# data envelopes locally with the exported private key. This wrapper exposes only
# what the importer/controller need, and normalises the gem's immutable Struct
# value objects into plain hashes (with string amounts) so they can be persisted
# as JSONB and re-read the same way regardless of source.
class Provider::OpenBankingIo
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

  attr_reader :api_base_url

  def initialize(api_base_url:, api_key:, private_key:)
    @api_base_url = api_base_url.to_s.strip

    @client = OpenBankingIO::Client.new(
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
    rescue OpenBankingIO::HTTPError => e
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
