# Determines the appropriate cost_basis value and source when updating a holding.
#
# Used by both Materializer (for trade-derived calculations) and
# ProviderImportAdapter (for provider-supplied values) to ensure consistent
# reconciliation logic across all data sources.
#
# Priority hierarchy: manual > calculated > provider > unknown
#
class Holding::CostBasisReconciler
  # Determines the appropriate cost_basis value and source for a holding update
  #
  # @param existing_holding [Holding, nil] The existing holding record (nil for new)
  # @param incoming_cost_basis [BigDecimal, nil] The incoming cost_basis value
  # @param incoming_source [String] The source of incoming data ('calculated', 'provider')
  # @return [Hash] { cost_basis: value, cost_basis_source: source, should_update: boolean }
  def self.reconcile(existing_holding:, incoming_cost_basis:, incoming_source:)
    # Treat zero cost_basis from provider as unknown
    if incoming_source == "provider" && (incoming_cost_basis.nil? || incoming_cost_basis.zero?)
      incoming_cost_basis = nil
    end

    # New holding - use whatever we have
    if existing_holding.nil?
      return {
        cost_basis: incoming_cost_basis,
        cost_basis_source: incoming_cost_basis.present? ? incoming_source : nil,
        should_update: true
      }
    end

    # Locked - never overwrite
    if existing_holding.cost_basis_locked?
      return {
        cost_basis: existing_holding.cost_basis,
        cost_basis_source: existing_holding.cost_basis_source,
        should_update: false
      }
    end

    # Check priority - can the incoming source replace the existing?
    if existing_holding.cost_basis_replaceable_by?(incoming_source)
      if incoming_cost_basis.present?
        # Avoid writes when nothing would change (common when re-materializing)
        if existing_holding.cost_basis_source == incoming_source && existing_holding.cost_basis == incoming_cost_basis
          return {
            cost_basis: existing_holding.cost_basis,
            cost_basis_source: existing_holding.cost_basis_source,
            should_update: false
          }
        end

        return {
          cost_basis: incoming_cost_basis,
          cost_basis_source: incoming_source,
          should_update: true
        }
      end
    end

    # Keep existing (equal or lower priority, or incoming is nil)
    {
      cost_basis: existing_holding.cost_basis,
      cost_basis_source: existing_holding.cost_basis_source,
      should_update: false
    }
  end
end
