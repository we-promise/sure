module Financekit
  VERSION = 2
  MAX_BYTES = 1_048_576
  MAX_RECORDS = 500
  MAX_ACCOUNTS = 20
  MAX_QUEUED = 100
  MAX_ATTEMPTS = 5
  TOKEN_BYTES = 32

  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, status = 422)
      @code = code
      @status = status
      super(code)
    end
  end

  def self.require!(condition, code = "invalid_payload", status = 422)
    raise Error.new(code, status) unless condition
  end

  def self.enabled?(family)
    ENV["FINANCEKIT_ENABLED"] == "true" &&
      ENV.fetch("FINANCEKIT_FAMILY_IDS", "").split(",").map(&:strip).include?(family.id)
  end

  def self.issue_credential
    SecureRandom.urlsafe_base64(TOKEN_BYTES, false)
  end

  def self.credential_digest(credential)
    Digest::SHA256.hexdigest(credential.to_s)
  end
end
