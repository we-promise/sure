# Base class for insight generators. Subclasses compute a financial signal in
# pure Ruby and return GeneratedInsight records — numbers only, no prose. The
# prose (`body`) is written later by Insight::BodyWriter, and only when the
# insight is new or its numbers changed, so nightly re-runs don't re-invoke
# the LLM for unchanged insights.
class Insight::Generator
  # `facts` doubles as the i18n interpolation args for the template fallback
  # and as the grounding data handed to the LLM writer. `metadata` is what the
  # job compares between runs to decide whether an insight changed — keep its
  # values JSON-primitive (floats, strings, ISO dates) so comparisons are stable.
  GeneratedInsight = Data.define(
    :insight_type,
    :priority,
    :title,
    :template_key,
    :facts,
    :metadata,
    :currency,
    :period_start,
    :period_end,
    :dedup_key
  )

  class << self
    # Declares the insight_type values this generator can emit. The job uses
    # this to expire stale insights: a visible insight whose type belongs to a
    # generator that ran successfully, but whose dedup_key was not regenerated,
    # has had its condition clear.
    def produces(*types)
      @produced_types = types.flatten.map(&:to_s)
    end

    def produced_types
      @produced_types || []
    end
  end

  def initialize(family)
    @family = family
  end

  def generate
    raise NotImplementedError
  end

  private
    attr_reader :family

    def income_statement
      @income_statement ||= IncomeStatement.new(family)
    end

    def balance_sheet
      @balance_sheet ||= BalanceSheet.new(family)
    end

    def build_insight(insight_type:, priority:, title:, template_key:, facts:, dedup_key:, metadata:, period: nil)
      GeneratedInsight.new(
        insight_type: insight_type,
        priority: priority,
        title: title,
        template_key: template_key,
        facts: facts,
        metadata: metadata,
        currency: family.currency,
        period_start: period&.start_date,
        period_end: period&.end_date,
        dedup_key: dedup_key
      )
    end

    def format_money(amount)
      Money.new(amount, family.currency).format
    end

    # Normalizes BigDecimal/Rational math results so metadata survives a jsonb
    # round-trip unchanged (BigDecimal#as_json is a string, which would make
    # every nightly run look like a material change).
    def round(amount, precision = 2)
      amount.to_f.round(precision)
    end

    def month_token(date = Date.current)
      date.strftime("%Y-%m")
    end

    # Formats a number for display facts with a true minus sign (U+2212) —
    # the app types negatives with a minus, not a hyphen. Keep raw numerics
    # in `metadata`; this is for interpolation into template/LLM prose only.
    def signed_number(value)
      value.negative? ? "−#{value.abs}" : value.to_s
    end
end
