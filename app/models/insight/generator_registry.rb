# Runs every insight generator for a family. A failing generator is logged to
# the super-admin debug UI and skipped, so one bad signal never blocks the rest
# of the nightly run.
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

  def initialize(family)
    @family = family
  end

  def generate_all
    GENERATORS.flat_map do |generator_class|
      generator_class.new(family).generate
    rescue => e
      DebugLogEntry.capture(
        category: "insights",
        level: "error",
        message: "#{generator_class.name} failed: #{e.class}: #{e.message}",
        source: "Insight::GeneratorRegistry",
        family: family,
        metadata: { generator: generator_class.name, backtrace: e.backtrace&.first(5) }
      )
      []
    end
  end

  private
    attr_reader :family
end
