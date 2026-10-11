# Turns a raw bank statement label into the merchant a human would name, with no
# LLM involved.
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
# The markers it strips live in Dictionary, one pack per region, and every pack
# is always active. This class holds only the rules that are true of a bank
# label whatever country wrote it: a marker, then a date, then noise, then the
# merchant.
#
# Casing is deliberately left alone. Bank labels are often upper case and
# titlecasing them mangles acronyms (SNCF, EDF, RATP, FNAC, HSBC, HMRC, ASOS,
# ANZ), so the value here is removing noise, not prettifying.
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

  # A refund label usually nests the rail it reverses ("ANNULATION CB FNAC",
  # "Refund Card Payment to ASOS", "SEPA INCASSO TERUGBOEKING"). The prefix loop
  # stops at the first match, so the nested marker would survive into the
  # merchant name and split the refund away from the purchase it reverses, which
  # is exactly the grouping this class exists to fix. The rail stays "refund":
  # that is the useful signal.
  NESTED_RAILS = %w[card direct_debit].freeze

  # Payment aggregators put the real merchant after a star. The aggregator name
  # is dropped: it identifies the rail, not who was paid. The short codes are
  # safe here only because the star is required.
  AGGREGATOR = /\A(?:PAYPAL|PP|SUMUP|SQC?|STRIPE|IZETTLE|ZETTLE|LYDIA|MOLLIE|ADYEN|GOCARDLESS|TST|CLV|WPY|UBER|GOOGLE|EB|IC|SP|DD)\s*\*\s*/i

  # DD/MM, DD/MM/YY and DD/MM/YYYY, plus the dotted and dashed variants. Which
  # of the two leading numbers is the day depends on the region: see
  # #resolve_day_and_month.
  SLASHED_DATE = %r{\b(?:(?:DU|ON)\s+)?(\d{2})[/.\-](\d{2})(?:[/.\-](\d{2,4}))?\b}i
  # Only read after an explicit DU, because a bare 6-digit run is far more often
  # a card or contract number than a date.
  COMPACT_DATE = /\bDU\s+(\d{2})(\d{2})(\d{2})\b/i
  # "27DEC24", "02 SEP", "ON 03 SEP 24". English month abbreviations only, and
  # the negative lookahead is load-bearing: without it DEC would match inside
  # "3 DECADES" and MAR inside "5 MARCH ST".
  #
  # The optional ON is consumed only when a date actually follows it, the way DU
  # is above. Swallowing it as a connector instead would turn Barclays' "Card
  # Payment ON RUNNING" into a merchant called RUNNING.
  MONTHS = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC].freeze
  ALPHA_DATE = /\b(?:ON\s+)?(\d{1,2})[\s\-]?(#{MONTHS.join('|')})(?![A-Z])[\s\-]?(\d{2,4})?\b/i

  # Everything from these markers onward is the payment system talking to
  # itself. Truncating is safe because they always trail the counterparty:
  # SEPA structured references (EREF+, MREF+, CRED+) and the US ACH descriptor
  # fields, where "AMERICAN EXPRESS DES:ACH PMT INDN: ..." carries the payee
  # first and the plumbing after.
  TRUNCATORS = [
    /\b(?:EREF|KREF|MREF|CRED|DEBT|RREF|BREF)\+/i,
    /\b(?:DES|INDN|CO\s+ID|ORIG\s+ID|DESC\s+DATE|SEC)\s*:/i,
    /\b(?:MANDATSREFERENZ|GL(?:AE|Ä)UBIGER-?ID|INCASSANT\s*ID|MACHTIGING\s*ID)\b/i
  ].freeze

  NOISE = [
    # Card number, in the languages that name the card before it.
    /\b(?:CARTE|CB|CARD|KARTE|KARTENNUMMER|KAARTNR|PASVOLGNR|TARJETA)\s*(?:N[O°R]?\.?\s*)?\*?\d{4,}\b/i,
    /\bCARD\s+ENDING(?:\s+IN)?\s*\*?\d{4}\b/i,
    /\bCKCD(?:\s*[X\d]{4}){1,4}/i,
    /\b[X*]{4,}\d{0,4}\b/i,                          # masked PAN
    # \b after the word is load-bearing: without it "REF" matched inside
    # "REFUNDO TAX" and reduced a real payee to "TAX".
    /\b(?:REF|REFERENCE|MDT|MANDAT|MANDATE|NUM)\b\.?\s*[:#]?\s*[A-Z0-9-]{4,}\b/i,
    # The number-marker form runs straight into its digits ("NR00012345",
    # "GA NR0001"), so it asks for digits instead of a boundary.
    /\b(?:GAA?\s*NR|N[O°R]|NR)\.?\s*[:#]?\s*\d{4,}\b/i,
    /\b(?:AUTH|AUTHORISATION|AUTHORIZATION)\s*(?:CODE|NO)?\.?\s*[:#]?\s*[A-Z0-9]{4,}\b/i,
    /\b(?:TERM|TERMINAL|TID|MID|TRACE|SEQ|TXN|TRN)\s*(?:ID|NO|N[O°])?\.?\s*[:#]?\s*[A-Z0-9-]{4,}\b/i,
    /\b\d{6,}\b/,                                    # contract / cheque numbers
    /\b(?:RECURRING|PENDING)\s*\z/i,
    /\b(?:PPD|CCD|IAT|ARC|BOC|RCK)\s*\z/i            # trailing ACH SEC codes
  ].freeze

  # A terminal id or card last-four sits between the marker and the merchant on
  # NatWest ("POS 5250 27DEC24 TESCO"), RBC ("Interac purchase - 1234 TIM
  # HORTONS") and most ATM labels. It varies per visit, so leaving it in splits
  # one payee into dozens. Only stripped at the very front, and only once a
  # marker was actually consumed: a global short-digit strip would eat the store
  # number in "TESCO STORE 3243", which is part of the name.
  TERMINAL_ID = /\A\d{2,6}\b[\s:.,#\-]*/

  class << self
    # `on:` is the entry date, used only to pick a year for a DD/MM label that
    # carries none. Pass nil and operation_date is nil rather than guessed.
    # `region:` is an optional country hint (a `families.country` value). It is
    # consulted only when no marker matched, since a marker identifies the bank's
    # own conventions far more reliably than a family's settings do.
    def normalize(raw, on: nil, region: nil)
      original = raw.to_s
      working, rail, date_order = strip_rail(original.dup)

      working = strip_nested_rail(working) if rail == "refund"
      working = truncate_at_reference(working)

      date_order ||= Dictionary.date_order_for_region(region)
      operation_date, working = extract_operation_date(working, on: on, order: date_order)

      working = working.sub(TERMINAL_ID, "") if rail

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
      def strip_rail(working)
        Dictionary.candidates_for(working).each do |_position, rail, date_order, pattern|
          next unless working.match?(pattern)

          return [ working.sub(pattern, ""), rail, date_order ]
        end

        [ working, nil, nil ]
      end

      def strip_nested_rail(working)
        Dictionary.entries_for_rails(NESTED_RAILS).each do |_rail, _order, pattern|
          return working.sub(pattern, "") if working.match?(pattern)
        end

        working
      end

      def truncate_at_reference(working)
        TRUNCATORS.each do |pattern|
          match = working.match(pattern)
          next unless match && match.begin(0).positive?

          working = working[0...match.begin(0)]
        end

        working
      end

      # Removal and resolution are separate concerns. A DD/MM label with no
      # entry date to anchor the year still has to lose the digits, otherwise
      # "02/09" ends up inside the merchant name and every month reads as a
      # different payee.
      def extract_operation_date(working, on:, order:)
        match = working.match(COMPACT_DATE)
        return [ build_date(match[1], match[2], match[3], on: on), working.sub(COMPACT_DATE, " ") ] if match

        match = working.match(ALPHA_DATE)
        if match
          month = MONTHS.index(match[2].upcase) + 1
          return [ build_date(match[1], month, match[3], on: on), working.sub(ALPHA_DATE, " ") ]
        end

        match = working.match(SLASHED_DATE)
        if match
          day, month = resolve_day_and_month(match[1], match[2], order)
          return [ build_date(day, month, match[3], on: on), working.sub(SLASHED_DATE, " ") ]
        end

        [ nil, working ]
      end

      # Only the Americas write the month first, and the label's own marker has
      # already told us which convention wrote it. A value above 12 settles the
      # question on its own, whatever the region says, so a misconfigured
      # `families.country` can only ever mis-read a genuinely ambiguous date.
      def resolve_day_and_month(first, second, order)
        return [ first, second ] if first.to_i > 12
        return [ second, first ] if second.to_i > 12

        order == :mdy ? [ second, first ] : [ first, second ]
      end

      # A label written DD/MM with no year sits a few days before the entry
      # date, so the entry's year is right except across a New Year boundary,
      # where the label belongs to the previous year.
      def build_date(day, month, year, on:)
        day = day.to_i
        month = month.to_i
        return nil unless day.between?(1, 31) && month.between?(1, 12)

        if year.present?
          year = year.to_s
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
