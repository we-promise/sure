class RecurringTransaction
  # Rule-based first guess at what a detected recurring charge IS: a
  # subscription (a service auto-charging a card on file) or a bill (an
  # obligation you push money at). Deliberately transparent -- named keyword
  # lists and three documented heuristics, no opaque scoring -- and only a
  # DEFAULT: the Kind field on every bill stays user-editable, and detection
  # never reclassifies a series after creation.
  #
  # The category comes along for free: a cluster's entries usually already
  # carry one (from enrichment or the user's own rules), so the series
  # inherits the most common one.
  class Classifier
    # Services that are subscriptions essentially always.
    SUBSCRIPTION_KEYWORDS = %w[
      netflix spotify hulu disney hbo max paramount peacock crunchyroll
      youtube prime audible kindle icloud apple.com/bill google\ one
      playstation xbox nintendo twitch patreon substack onlyfans
      dropbox github openai anthropic claude chatgpt midjourney canva adobe
      microsoft\ 365 office\ 365 notion slack zoom 1password lastpass
      bitwarden nordvpn expressvpn sirius pandora tidal deezer duolingo
      headspace calm grammarly peloton planet\ fitness la\ fitness
      grok x.ai xai
    ].freeze

    # Wording that marks classic push-payment obligations: utilities,
    # telecom, insurance, housing, taxes.
    BILL_KEYWORDS = %w[
      electric power energy gas water sewer utility utilit insurance insur
      mortgage rent lease loan hoa property tax comcast xfinity spectrum
      cox centurylink frontier at&t verizon t-mobile tmobile mint\ mobile
      wireless phone internet interest finance\ charge
    ].freeze

    # Push-payment fingerprints in raw descriptors.
    ACH_MARKERS = %w[ach web\ pmt webpmt billpay bill\ pay online\ pmt e-pay epay].freeze

    # Above this, a flat recurring charge is more likely rent-or-service
    # than a streaming plan.
    SUBSCRIPTION_AMOUNT_CEILING = BigDecimal("150")

    Result = Data.define(:bill_type, :category_id, :autopay)

    def self.classify(name:, entries:, account: nil)
      new(name: name, entries: entries, account: account).classify
    end

    attr_reader :name, :entries, :account

    def initialize(name:, entries:, account: nil)
      @name = name.to_s.downcase
      @entries = entries
      @account = account
    end

    def classify
      subscription = subscription?

      Result.new(
        bill_type: subscription ? "subscription" : "bill",
        category_id: modal_category_id,
        # A subscription IS an auto-charge: it belongs on the list but is
        # not a task. User-editable like everything else here.
        autopay: subscription
      )
    end

    private
      def subscription?
        return false if matches?(BILL_KEYWORDS) || matches?(ACH_MARKERS)
        return true if matches?(SUBSCRIPTION_KEYWORDS)

        # No name signal: a to-the-cent identical charge, modest in size,
        # hitting a credit card, is the shape of a card-on-file service.
        flat_amounts? && modest_amount? && credit_card_account?
      end

      def matches?(keywords)
        keywords.any? { |keyword| name.include?(keyword) }
      end

      def flat_amounts?
        amounts = entries.map { |entry| entry.amount.abs }
        amounts.uniq.size == 1
      end

      def modest_amount?
        entries.first.amount.abs <= SUBSCRIPTION_AMOUNT_CEILING
      end

      def credit_card_account?
        account&.accountable_type == "CreditCard"
      end

      def modal_category_id
        entries.filter_map { |entry| entry.entryable.try(:category_id) }
               .tally
               .max_by { |_category_id, count| count }
               &.first
      end
  end
end
