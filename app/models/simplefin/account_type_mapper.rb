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
    CREDIT_BRAND_KEYWORDS = /\b(visa|mastercard|amex|american express|discover|apple card|freedom unlimited|quicksilver)\b/i.freeze
    LOAN_KEYWORDS = /\b(loan|mortgage|heloc|line of credit|loc)\b/i.freeze

    # Explicit investment subtype tokens mapped to known SUBTYPES keys
    EXPLICIT_INVESTMENT_TOKENS = {
      /\btraditional\s+ira\b/i => "ira",
      /\broth\s+ira\b/i => "roth_ira",
      /\broth\s+401\(k\)\b|\broth\s*401k\b/i => "roth_401k",
      /\b401\(k\)\b|\b401k\b/i => "401k",
      /\b529\s*plan\b|\b529\b/i => "529_plan",
      /\bhsa\b|\bhealth\s+savings\s+account\b/i => "hsa",
      /\bpension\b/i => "pension",
      /\bmutual\s+fund\b/i => "mutual_fund",
      /\b403b\b|\b403\(b\)\b/i => "403b",
      /\btsp\b/i => "tsp"
    }.freeze

    # Public API
    # @param name [String, nil]
    # @param holdings [Array<Hash>, nil]
    # @param extra [Hash, nil] - provider extras when present
    # @param balance [Numeric, String, nil]
    # @param available_balance [Numeric, String, nil]
    # @return [Inference] e.g. Inference.new(accountable_type: "Investment", subtype: "retirement", confidence: :high)
    def self.infer(name:, holdings: nil, extra: nil, balance: nil, available_balance: nil, institution: nil)
      nm_raw = name.to_s
      nm = nm_raw
      # Normalized form to catch variants like RothIRA, Traditional-IRA, 401(k)
      nm_norm = nm_raw.downcase.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
      inst = institution.to_s
      holdings_present = holdings.is_a?(Array) && holdings.any?
      bal = (balance.to_d rescue nil)
      avail = (available_balance.to_d rescue nil)

      # 0) Explicit retirement/plan tokens → Investment with explicit subtype (match against normalized name)
      if (explicit_sub = EXPLICIT_INVESTMENT_TOKENS.find { |rx, _| nm_norm.match?(rx) }&.last)
        if defined?(Investment::SUBTYPES) && Investment::SUBTYPES.key?(explicit_sub)
          return Inference.new(accountable_type: "Investment", subtype: explicit_sub, confidence: :high)
        else
          return Inference.new(accountable_type: "Investment", subtype: nil, confidence: :high)
        end
      end

      # 1) Holdings present => Investment (high confidence)
      if holdings_present
        # Do not guess generic retirement; explicit tokens handled above
        return Inference.new(accountable_type: "Investment", subtype: nil, confidence: :high)
      end

      # 2) Name suggests LOAN (high confidence)
      if LOAN_KEYWORDS.match?(nm)
        return Inference.new(accountable_type: "Loan", confidence: :high)
      end

      # 3) Credit card signals
      # - Name contains credit/card (medium to high)
      # - Card brands (Visa/Mastercard/Amex/Discover/Apple Card) → high
      # - Or negative balance with available-balance present (medium)
      if CREDIT_NAME_KEYWORDS.match?(nm) || CREDIT_BRAND_KEYWORDS.match?(nm) || CREDIT_BRAND_KEYWORDS.match?(inst)
        return Inference.new(accountable_type: "CreditCard", confidence: :high)
      end
      # Strong combined signal for credit card: negative balance and positive available-balance
      if bal && bal < 0 && avail && avail > 0
        return Inference.new(accountable_type: "CreditCard", confidence: :high)
      end

      # 4) Retirement keywords without holdings still point to Investment (retirement)
      if RETIREMENT_KEYWORDS.match?(nm)
        # If the name contains 'brokerage', avoid forcing retirement subtype
        subtype = BROKERAGE_KEYWORD.match?(nm) ? nil : "retirement"
        return Inference.new(accountable_type: "Investment", subtype: subtype, confidence: :high)
      end

      # 5) Default
      Inference.new(accountable_type: "Depository", confidence: :low)
    end
  end
end
