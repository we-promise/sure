class RecurringTransaction
  # Turns charge history into a reviewed bill-configuration proposal via the
  # family's configured LLM provider. Two modes:
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
      def run(charges:, current_config:)
        raise Error, "No LLM provider configured" unless llm_provider
        raise Error, "No charge history to analyze" if charges.empty?

        result = llm_provider.suggest_bill_setup(
          charges: charges,
          categories: family.categories.pluck(:name),
          current_config: current_config,
          family: family
        )

        raise Error, "Provider failed: #{result.error&.message}" unless result.success?

        normalize(result.data)
      end

      def llm_provider
        Provider::Registry.preferred_llm_provider
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
          frequency: detection.key,
          day_of_month: detection.day_of_month,
          weekday: detection.weekday,
          month_of_year: detection.month_of_year,
          category: series.category&.name,
          bill_type: series.bill_type,
          autopay: series.autopay
        }.compact
      end

      def normalize(raw)
        category = resolve_category(raw.category_name)

        Suggestion.new(
          name: raw.name,
          amount: positive_or_nil(raw.amount),
          frequency: raw.frequency.presence_in(FrequencyPreset::PRESETS),
          day_of_month: in_range(raw.day_of_month, 1..31),
          weekday: in_range(raw.weekday, 0..6),
          month_of_year: in_range(raw.month_of_year, 1..12),
          category_id: category&.id,
          category_name: category&.name,
          bill_type: raw.bill_type.presence_in(%w[bill subscription installment]),
          autopay: [ true, false ].include?(raw.autopay) ? raw.autopay : nil,
          confidence: raw.confidence.is_a?(Numeric) ? raw.confidence.to_f.clamp(0.0, 1.0) : nil,
          rationale: raw.rationale
        )
      end

      # This family's category or nothing: an LLM-invented name must never
      # become an id, and another family's category can never resolve here.
      def resolve_category(name)
        return nil if name.blank?

        family.categories.find_by(name: name) ||
          family.categories.find_by(Category.arel_table[:name].lower.eq(name.downcase))
      end

      def positive_or_nil(value)
        return nil unless value.is_a?(Numeric)

        value.positive? ? BigDecimal(value.to_s).abs : nil
      end

      def in_range(value, range)
        value.is_a?(Integer) && range.cover?(value) ? value : nil
      end
  end
end
