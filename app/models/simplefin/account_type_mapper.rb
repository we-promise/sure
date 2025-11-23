# frozen_string_literal: true

# Fallback-only inference for SimpleFIN-provided accounts.
# Conservative, used only to suggest a default type during setup/creation.
# Never overrides a user-selected type.
module Simplefin
  class AccountTypeMapper
    Inference = Struct.new(:accountable_type, :subtype, :confidence, keyword_init: true)

    RETIREMENT_KEYWORDS = /\b(401k|401\(k\)|403b|403\(b\)|tsp|ira|roth|retirement)\b/i.freeze
    BROKERAGE_KEYWORD = /\bbrokerage\b/i.freeze
    CREDIT_NAME_KEYWORDS = /\b(credit|card)\b/i.freeze
    CREDIT_BRAND_KEYWORDS = /\b(visa|mastercard|amex|american express|discover)\b/i.freeze
    LOAN_KEYWORDS = /\b(loan|mortgage|heloc|line of credit|loc)\b/i.freeze

    # Public API
    # @param name [String, nil]
    # @param holdings [Array<Hash>, nil]
    # @param extra [Hash, nil] - provider extras when present
    # @param balance [Numeric, String, nil]
    # @param available_balance [Numeric, String, nil]
    # @return [Inference] e.g. Inference.new(accountable_type: "Investment", subtype: "retirement", confidence: :high)
    def self.infer(name:, holdings: nil, extra: nil, balance: nil, available_balance: nil)
      nm = name.to_s
      holdings_present = holdings.is_a?(Array) && holdings.any?
      bal = (balance.to_d rescue nil)
      avail = (available_balance.to_d rescue nil)

      # 1) Holdings present => Investment (high confidence)
      if holdings_present
        subtype = retirement_hint?(nm, extra) ? "retirement" : nil
        return Inference.new(accountable_type: "Investment", subtype: subtype, confidence: :high)
      end

      # 2) Name suggests LOAN (high confidence)
      if LOAN_KEYWORDS.match?(nm)
        return Inference.new(accountable_type: "Loan", confidence: :high)
      end

      # 3) Credit card signals
      # - Name contains credit/card (medium to high)
      # - Or negative balance with available-balance present (medium)
      if CREDIT_NAME_KEYWORDS.match?(nm) || CREDIT_BRAND_KEYWORDS.match?(nm)
        return Inference.new(accountable_type: "CreditCard", confidence: :high)
      end
      if bal && bal < 0 && !avail.nil?
        return Inference.new(accountable_type: "CreditCard", confidence: :medium)
      end

      # 4) Retirement keywords without holdings still point to Investment (retirement)
      if RETIREMENT_KEYWORDS.match?(nm)
        return Inference.new(accountable_type: "Investment", subtype: "retirement", confidence: :high)
      end

      # 5) Default
      Inference.new(accountable_type: "Depository", confidence: :low)
    end

    def self.retirement_hint?(name, extra)
      return true if RETIREMENT_KEYWORDS.match?(name.to_s)

      # sometimes providers include hints in extra payload
      x = (extra || {}).with_indifferent_access
      candidate = [ x[:account_subtype], x[:type], x[:subtype], x[:category] ].compact.join(" ")
      RETIREMENT_KEYWORDS.match?(candidate)
    end
    private_class_method :retirement_hint?
  end
end
