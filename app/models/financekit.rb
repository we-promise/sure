module Financekit
  VERSION = 1
  MAX_BYTES = 1_048_576
  MAX_RECORDS = 500
  MAX_ACCOUNTS = 20

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
      ENV.fetch("FINANCEKIT_FAMILY_IDS", "").split(",").include?(family.id)
  end
end
