# Orchestrates all insight generators for a family.
# Catches errors per-generator so one failure doesn't block others.
class Insight::GeneratorRegistry
  ALL_GENERATORS = [
    Insight::Generators::SpendingAnomalyGenerator,
    Insight::Generators::CashFlowWarningGenerator,
    Insight::Generators::NetWorthMilestoneGenerator,
    Insight::Generators::SubscriptionAuditGenerator,
    Insight::Generators::SavingsRateChangeGenerator,
    Insight::Generators::IdleCashGenerator,
    Insight::Generators::BudgetInsightGenerator
  ].freeze

  def self.generate_for(family)
    ALL_GENERATORS.flat_map do |klass|
      klass.new(family).generate
    rescue => e
      Rails.logger.error("[Insight::GeneratorRegistry] #{klass.name} failed for family #{family.id}: #{e.message}")
      []
    end
  end
end
