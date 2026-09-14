# Parses the credentials.json bundle a user exports from open-banking.io and pastes into
# the provider panel.
#
# This lives on the model rather than in the controller because it is where the SSRF guard
# bites: OpenBankingIoItem.allowed_api_base_url? pins the host, and the base URL it
# validates is used verbatim by the HTTP client. Keeping the parse next to the guard means
# the whole surface is unit-testable without an HTTP request.
class OpenBankingIoItem::Credentials
  Result = Struct.new(:attributes, :error_key, keyword_init: true) do
    def valid? = error_key.nil?
  end

  def self.parse(raw_json)
    new(raw_json).parse
  end

  def initialize(raw_json)
    @raw_json = raw_json
  end

  def parse
    return failure("credentials_required") if @raw_json.blank?

    bundle = JSON.parse(@raw_json)
    # Valid JSON can still be the wrong shape (null, an array, or an encryptionKey that
    # isn't an object). Treat any non-hash bundle as invalid rather than letting the
    # ensuing []/dig raise NoMethodError and bubble up as a 500.
    return failure("credentials_invalid") unless bundle.is_a?(Hash)

    encryption_key = bundle["encryptionKey"]
    encryption_key = {} unless encryption_key.is_a?(Hash)

    api_base_url = bundle["apiBaseUrl"].presence
    # Reads the apiKey field from the user's pasted JSON at request time; it is not a
    # hardcoded secret and never appears in a URL. pipelock's "credential in URL" rule
    # false-positives on this assignment next to api_base_url.
    api_key = bundle["apiKey"].presence # pipelock:ignore
    private_key = encryption_key["privateKey"].presence || encryption_key["privateKeyPkcs8B64"].presence

    return failure("credentials_invalid") if api_base_url.blank? || api_key.blank? || private_key.blank?
    return failure("credentials_invalid_url") unless OpenBankingIoItem.allowed_api_base_url?(api_base_url)

    Result.new(attributes: { api_base_url: api_base_url, api_key: api_key, private_key: private_key })
  rescue JSON::ParserError, TypeError, NoMethodError
    failure("credentials_invalid")
  end

  private

    def failure(error_key)
      Result.new(attributes: {}, error_key: error_key)
    end
end
