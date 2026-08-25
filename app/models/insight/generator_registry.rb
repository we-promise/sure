# Runs every insight generator for a family. A failing generator is logged to
# the super-admin debug UI and skipped, so one bad signal never blocks the rest
# of the nightly run. The result records which insight types were produced by
# generators that ran to completion — the job only expires stale insights of
# those types, so a crashing generator can never wipe out its healthy insights.
class Insight::GeneratorRegistry
  GENERATORS = [
    Insight::Generators::SpendingAnomalyGenerator,
    Insight::Generators::CashFlowWarningGenerator,
    Insight::Generators::NetWorthMilestoneGenerator,
    Insight::Generators::SubscriptionAuditGenerator,
    Insight::Generators::SavingsRateChangeGenerator,
    Insight::Generators::IdleCashGenerator,
    Insight::Generators::BudgetInsightGenerator
  ].freeze

  Result = Data.define(:insights, :succeeded_types)

  def initialize(family)
    @family = family
  end

  def generate_all
    insights = []
    succeeded_types = []

    GENERATORS.each do |generator_class|
      insights.concat(generator_class.new(family).generate)
      succeeded_types.concat(generator_class.produced_types)
    rescue => e
      DebugLogEntry.capture(
        category: "insights",
        level: "error",
        message: "#{generator_class.name} failed: #{e.class}: #{e.message}",
        source: "Insight::GeneratorRegistry",
        family: family,
        metadata: { generator: generator_class.name, backtrace: e.backtrace&.first(5) }
      )
    end

    Result.new(insights: insights, succeeded_types: succeeded_types)
  end

  private
    attr_reader :family
end
