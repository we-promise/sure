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

  # Runs every generator, isolating failures so one broken signal never
  # blocks the rest. Returns Array<Insight::Generator::GeneratedInsight>.
  def generate_all
    GENERATORS.flat_map do |generator_class|
      generator_class.new(family).generate
    rescue => e
      Rails.logger.error("Insight generator #{generator_class} failed for family #{family.id}: #{e.message}")
      []
    end
  end

  private
    attr_reader :family
end
