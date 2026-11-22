# frozen_string_literal: true

# Fills a credit card's APR from what the bank reported in
# `GET /v1/account-details`.
#
# The rates are the product's published reference data, not a per-account
# figure, so this only fills a gap: an APR already on the card is either the
# user's or an earlier provider's and is left alone.
class RedbarkAccount::CreditCardDetailsProcessor < RedbarkAccount::DetailsProcessor
  SOURCE = "redbark"

  def process
    return unless credit_card
    return if details.blank?
    return unless details_fetched_this_sync?

    apply_apr
  end

  private
    def credit_card
      return @credit_card if defined?(@credit_card)

      @credit_card = account&.accountable_type == "CreditCard" ? account.accountable : nil
    end

    # `lendingRate` is not read for a card: nothing says which rate it is for.
    # Only untiered PURCHASE entries are candidates, because a tiered rate is
    # several rates wearing one entry and the payload does not say which band
    # the account sits in.
    def reported_apr
      return @reported_apr if defined?(@reported_apr)

      @reported_apr = single_purchase_rate
    end

    def single_purchase_rate
      rates = details[:lendingRates]

      unless rates.is_a?(Array)
        capture("Redbark account details carried no usable lendingRates", shape: rates.class.name) unless rates.nil?
        return nil
      end

      candidates = rates.select { |entry| entry.is_a?(Hash) && entry[:rateType].to_s.casecmp("PURCHASE").zero? }
      candidates = candidates.reject { |entry| Array(entry[:tiers]).any? }

      percentages = candidates.filter_map { |entry| to_percentage(entry[:rate]) }.uniq

      if percentages.size > 1
        capture("Redbark reported several purchase rates; recording none", candidate_count: percentages.size)
        return nil
      end

      percentages.first
    end

    # The API reports fractions: "0.1999" is 19.99%. The card's APR column
    # stores two decimal places, so the value is rounded half-up to match.
    def to_percentage(value)
      return nil if value.blank?

      (BigDecimal(value.to_s) * 100).round(2, BigDecimal::ROUND_HALF_UP)
    rescue ArgumentError, TypeError
      capture("Redbark reported an unparseable rate", value: value.to_s)
      nil
    end

    def apply_apr
      return if reported_apr.nil?
      return if credit_card.apr.present?

      credit_card.enrich_attributes({ apr: reported_apr }, source: SOURCE)
    end
end
