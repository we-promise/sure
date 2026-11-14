class RecurringTransaction
  # Turns charge history into a reviewed bill-configuration proposal through
  # Ai::Generations::SuggestBillSetup, on the web thread. Two modes:
  #
  #   suggest_from_entries  -- from candidate entries (the add dialog's
  #                            smart-fill; nothing exists yet)
  #   suggest_configuration -- from a series' own charge history against its
  #                            current settings (per-bill smart-configure;
  #                            only contradicted fields come back non-null)
  #
  # Every provider value is normalized here -- clamped to real presets and
  # ranges, category resolved to this family's own id -- so callers can trust
  # the shape without re-validating LLM output.
  class AiSetupSuggester
    Error = Class.new(StandardError)
    MAX_CHARGES = 40

    Suggestion = Data.define(
      :name, :amount, :frequency, :day_of_month, :weekday, :month_of_year,
      :category_id, :category_name, :bill_type, :autopay, :confidence, :rationale
    ) do
      # nil means "no proposal for this field"; false is a real proposal
      # (turn autopay off), so presence is non-nil rather than truthy.
      def any_proposal?
        [ name, amount, frequency, day_of_month, weekday, month_of_year, category_id, bill_type, autopay ].any? { |value| !value.nil? }
      end
    end

    attr_reader :family, :user

    def initialize(family, user:)
      @family = family
      @user = user
    end

    def suggest_from_entries(entries)
      run(charges: charges_from(entries), current_config: nil)
    end

    def suggest_configuration(series)
      run(
        charges: charges_from(series.matching_transactions),
        current_config: current_config_for(series)
      )
    end

    private
      # Runs on the web thread: smart-fill and smart-configure wait for the answer.
      def run(charges:, current_config:)
        raise Error, "No LLM provider configured" unless Ai.available?(:bill_setup, family:, user:)
        raise Error, "No charge history to analyze" if charges.empty?

        result = Ai::Generations::SuggestBillSetup.new(
          charges:, categories: family.categories.pluck(:name), current_config:, family:, user:
        ).call

        raise Error, "Provider failed: #{result.error&.message || result.availability&.reason}" unless result.success?

        normalize(result.value)
      end

      def charges_from(entries)
        entries.first(MAX_CHARGES).map do |entry|
          { date: entry.date.iso8601, amount: entry.amount.abs.to_s, name: entry.name }
        end
      end

      def current_config_for(series)
        detection = FrequencyPreset.detect(series)

        {
          name: series.display_name,
          amount: series.amount.abs.to_s,
          # Only PRESETS are offered back; anything else reads as custom.
          frequency: detection.key.presence_in(FrequencyPreset::PRESETS) || FrequencyPreset::CUSTOM,
          day_of_month: detection.day_of_month,
          weekday: detection.weekday,
          month_of_year: detection.month_of_year,
          category: series.category&.name,
          bill_type: series.bill_type,
          autopay: series.autopay
        }.compact
      end

      # Ai::Schema has already typed every field and turned values outside the presets and
      # ranges into nil; this resolves the category to the family's own, keeps only a positive
      # amount and clamps the confidence.
      def normalize(raw)
        category = resolve_category(raw[:category_name])

        Suggestion.new(
          **raw.slice(:name, :frequency, :day_of_month, :weekday, :month_of_year, :bill_type, :autopay, :rationale),
          amount: (BigDecimal(raw[:amount].to_s) if raw[:amount]&.positive?),
          category_id: category&.id,
          category_name: category&.name,
          confidence: raw[:confidence]&.to_f&.clamp(0.0, 1.0)
        )
      end

      # This family's category or nothing: an LLM-invented name must never
      # become an id, and another family's category can never resolve here.
      def resolve_category(name)
        return nil if name.blank?

        family.categories.find_by(name: name) ||
          family.categories.find_by(Category.arel_table[:name].lower.eq(name.downcase))
      end
  end
end
