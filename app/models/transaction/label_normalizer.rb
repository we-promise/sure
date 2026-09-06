# Turns a raw French bank statement label into the merchant a human would name,
# with no LLM involved.
#
# Why this is deterministic and not a prompt: merchant detection today runs only
# through Family::AutoMerchantDetector, which needs an LLM provider AND an
# active Rule to fire (Rule::ActionExecutor::AutoDetectMerchants), and
# `rules.active` defaults to false. On an install where neither is set up, every
# transaction keeps its raw label forever. Worse, RecurringTransaction::Identifier
# groups patterns by `entry.name` whenever merchant_id is nil, so
# "CB 02/09 CARREFOUR" and "CB 04/10 CARREFOUR" look like two different payees
# and no recurring series is ever detected. Cleaning the label therefore fixes
# grouping and categorization at once, before any model is asked anything.
#
# Casing is deliberately left alone. Bank labels are upper case and titlecasing
# them mangles the acronyms that are most of the French retail landscape (SNCF,
# EDF, RATP, FNAC), so the value here is removing noise, not prettifying.
class Transaction::LabelNormalizer
  # `operation_date` is the date embedded in the label by the bank. On a card
  # payment it is the date the card was used, which is NOT necessarily
  # entries.date (that column holds whatever the provider chose, often the
  # settlement date). It is the only surviving trace of the operation date in
  # the system, so it is returned rather than discarded.
  Result = Data.define(:name, :rail, :operation_date) do
    def normalized?(original)
      name != original
    end
  end

  # Ordered: the first prefix that matches wins, so the longer, more specific
  # phrasings must be listed before the bare abbreviations they contain.
  RAIL_PREFIXES = [
    [ "card",          /\A(?:ACHAT\s+|PAIEMENT\s+)?(?:FACT(?:URE)?\s+CARTE|CARTE\s+BANCAIRE|CARTE|CB)\b[\s:.-]*/i ],
    [ "card",          /\A(?:PAIEMENT\s+)?PSC\b[\s:.-]*/i ],
    [ "direct_debit",  /\A(?:PRLV|PRELEVEMENT|PRELEVMNT)(?:\s+SEPA)?(?:\s+DE)?\b[\s:.-]*/i ],
    [ "transfer",      /\A(?:VIR(?:EMENT)?)(?:\s+(?:SEPA|INST(?:ANTANE)?|RECU|EMIS|PERMANENT))*(?:\s+(?:DE|POUR|EN\s+FAVEUR\s+DE))?\b[\s:.-]*/i ],
    [ "withdrawal",    /\A(?:RETRAIT)(?:\s+(?:DAB|CARTE|ESPECES))?\b[\s:.-]*/i ],
    [ "cheque",        /\A(?:CHEQUE|CHQ)(?:\s+N[O°]?)?\b[\s:.-]*/i ],
    [ "fee",           /\A(?:COMMISSION\s+D?\s*INTERVENTION|COMMISSION|FRAIS|AGIOS|COTIS(?:ATION)?)\b[\s:.-]*/i ],
    # Lookahead: only the "ECHEANCE"/"REMB" marker is consumed. Unlike "CB" or
    # "PRLV SEPA", the word PRET names what is being paid, so dropping it would
    # turn "ECHEANCE PRET ETUDIANT" into the bare "ETUDIANT".
    [ "loan_payment",  /\A(?:ECH(?:EANCE)?|REMB(?:OURSEMENT)?)\b[\s:.-]*(?=PRET\b)/i ],
    # Listed after loan_payment so "REMB PRET" is read as a loan instalment, not
    # as money coming back. Sure has no refund concept at all (no model, no
    # kind, no link to the refunded transaction, a refund is just a negative
    # amount that reads as "income"), so this label prefix is the only signal
    # available that an inflow is a reversal rather than earnings.
    [ "refund",        /\A(?:AVOIR|ANNULATION|REMBOURSEMENT|REMBT|REMB)\b[\s:.-]*/i ]
  ].freeze

  # A refund label usually nests the rail it reverses ("ANNULATION CB FNAC",
  # "REMBOURSEMENT CARTE FNAC"). The prefix loop stops at the first match, so
  # the card marker would survive into the merchant name and split the refund
  # away from the purchase it reverses, which is exactly the grouping this
  # class exists to fix. The rail stays "refund": that is the useful signal.
  NESTED_CARD_PREFIXES = RAIL_PREFIXES.select { |rail, _| rail == "card" }.map(&:last).freeze

  # Payment aggregators put the real merchant after a star. The aggregator name
  # is dropped: it identifies the rail, not who was paid.
  AGGREGATOR = /\A(?:PAYPAL|SUMUP|SQ|SQC?\*?|STRIPE|IZETTLE|ZETTLE|LYDIA)\s*\*\s*/i

  # DD/MM, DD/MM/YY and DD/MM/YYYY, plus the dotted and dashed variants.
  SLASHED_DATE = %r{\b(?:DU\s+)?(\d{2})[/.\-](\d{2})(?:[/.\-](\d{2,4}))?\b}i
  # Only read after an explicit DU, because a bare 6-digit run is far more often
  # a card or contract number than a date.
  COMPACT_DATE = /\bDU\s+(\d{2})(\d{2})(\d{2})\b/i

  NOISE = [
    /\b(?:CARTE|CB)\s*(?:N[O°]?\s*)?\*?\d{4,}\b/i,  # trailing card number
    /\b[X*]{4,}\d{0,4}\b/i,                          # masked PAN
    /\b(?:REF|MDT|MANDAT|NUM|N[O°])\.?\s*[:#]?\s*[A-Z0-9-]{4,}\b/i,
    /\b\d{6,}\b/                                     # contract / cheque numbers
  ].freeze

  class << self
    # `on:` is the entry date, used only to pick a year for a DD/MM label that
    # carries none. Pass nil and operation_date is nil rather than guessed.
    def normalize(raw, on: nil)
      original = raw.to_s
      working = original.dup

      rail = nil
      RAIL_PREFIXES.each do |candidate_rail, pattern|
        next unless working.match?(pattern)

        working = working.sub(pattern, "")
        rail = candidate_rail
        break
      end

      if rail == "refund"
        nested = NESTED_CARD_PREFIXES.find { |pattern| working.match?(pattern) }
        working = working.sub(nested, "") if nested
      end

      operation_date, working = extract_operation_date(working, on: on)

      if working.match?(AGGREGATOR)
        working = working.sub(AGGREGATOR, "")
        rail ||= "card"
      end

      NOISE.each { |pattern| working = working.gsub(pattern, " ") }

      name = tidy(working)
      # A label that is nothing but noise (a cheque number, a bare reference)
      # keeps its original text: an empty name is worse than an ugly one.
      name = original if name.length < 2

      Result.new(name: name, rail: rail, operation_date: operation_date)
    end
  end

  class << self
    private
      # Removal and resolution are separate concerns. A DD/MM label with no
      # entry date to anchor the year still has to lose the digits, otherwise
      # "02/09" ends up inside the merchant name and every month reads as a
      # different payee.
      def extract_operation_date(working, on:)
        [ COMPACT_DATE, SLASHED_DATE ].each do |pattern|
          match = working.match(pattern)
          next unless match

          return [ build_date(match[1], match[2], match[3], on: on), working.sub(pattern, " ") ]
        end

        [ nil, working ]
      end

      # A label written DD/MM with no year sits a few days before the entry
      # date, so the entry's year is right except across a New Year boundary,
      # where the label belongs to the previous year.
      def build_date(day, month, year, on:)
        day = day.to_i
        month = month.to_i
        return nil unless day.between?(1, 31) && month.between?(1, 12)

        if year.present?
          full_year = year.length == 2 ? 2000 + year.to_i : year.to_i
          return safe_date(full_year, month, day)
        end

        return nil if on.blank?

        candidate = safe_date(on.year, month, day)
        return nil if candidate.nil?

        candidate > on ? safe_date(on.year - 1, month, day) : candidate
      end

      def safe_date(year, month, day)
        Date.new(year, month, day)
      rescue Date::Error
        nil
      end

      def tidy(value)
        value.gsub(/[*]/, " ")
             .gsub(/\s+/, " ")
             .strip
             .sub(/\A[[:punct:]\s]+/, "")
             .sub(/[[:punct:]\s]+\z/, "")
             .strip
      end
  end
end
