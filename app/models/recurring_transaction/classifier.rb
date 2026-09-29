class RecurringTransaction
  # Rule-based first guess at what a detected charge is: a subscription (a
  # service auto-charging a card on file) or a bill (an obligation you push
  # money at). Transparent by design -- keyword lists and three heuristics, no
  # scoring -- and only a default, since Kind stays user-editable and detection
  # never reclassifies after creation.
  #
  # Category is inherited from the most common one across the cluster's
  # entries.
  class Classifier
    # Services that are subscriptions essentially always.
    SUBSCRIPTION_KEYWORDS = %w[
      netflix spotify hulu disney hbo hbo\ max paramount peacock crunchyroll
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
      electric power energy gas water sewer utility utilit* insurance insur*
      mortgage rent lease loan hoa property tax comcast xfinity spectrum
      cox centurylink frontier at&t verizon t-mobile tmobile mint\ mobile
      wireless phone internet interest finance\ charge
    ].freeze

    # Buy-now-pay-later and financing: a fixed run of payments, then done.
    INSTALLMENT_KEYWORDS = %w[klarna affirm afterpay sezzle zip\ pay uplift].freeze

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
      kind =
        if matches?(INSTALLMENT_KEYWORDS)
          "installment"
        elsif subscription?
          "subscription"
        else
          "bill"
        end

      Result.new(
        bill_type: kind,
        category_id: modal_category_id,
        # Subscriptions and BNPL plans are auto-charges: on the list, not a
        # task.
        autopay: kind != "bill"
      )
    end

    private
      def subscription?
        return false if matches?(BILL_KEYWORDS) || matches?(ACH_MARKERS)
        return true if matches?(SUBSCRIPTION_KEYWORDS)

        # No name signal: an identical-to-the-cent modest charge on a credit
        # card is the shape of a card-on-file service.
        flat_amounts? && modest_amount? && credit_card_account?
      end

      # Whole words only. A substring test let "max" claim Maxwell Plumbing
      # and "gas" claim a gastropub, and a false subscription match also set
      # autopay, which removes the row from the needs-action list. A trailing
      # "*" marks a stem that may carry a suffix, so "utilit*" still reaches
      # "UTILITIES" without a bare stem matching inside unrelated words.
      def matches?(keywords)
        keywords.any? do |keyword|
          if keyword.end_with?("*")
            name.match?(/\b#{Regexp.escape(keyword.delete_suffix('*'))}\w*/)
          else
            name.match?(/\b#{Regexp.escape(keyword)}\b/)
          end
        end
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
