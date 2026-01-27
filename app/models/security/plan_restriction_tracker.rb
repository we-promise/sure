# Tracks securities that require a higher plan to fetch prices from data providers.
# Uses Rails cache to store restriction info, keyed by provider and security ID.
# This allows the settings page to warn users about tickers that need a paid plan.
#
# Note: Currently API keys are configured at the instance level (not per-family),
# so restrictions are shared across all families using the same provider.
module Security::PlanRestrictionTracker
  extend ActiveSupport::Concern

  CACHE_KEY_PREFIX = "security_plan_restriction"
  CACHE_EXPIRY = 7.days

  # Pattern to detect TwelveData plan upgrade errors
  PLAN_UPGRADE_PATTERN = /available starting with (\w+)/i

  class_methods do
    # Records that a security requires a higher plan to fetch data
    # @param security_id [Integer] The security ID
    # @param error_message [String] The error message from the provider
    # @param provider [String] The provider name (e.g., "TwelveData")
    def record_plan_restriction(security_id:, error_message:, provider:)
      required_plan = extract_required_plan(error_message)
      return unless required_plan

      cache_key = plan_restriction_cache_key(provider, security_id)
      Rails.cache.write(cache_key, {
        required_plan: required_plan,
        provider: provider,
        recorded_at: Time.current.iso8601
      }, expires_in: CACHE_EXPIRY)
    end

    # Clears the plan restriction for a security (e.g., if user upgrades their plan)
    # @param security_id [Integer] The security ID
    # @param provider [String] The provider name
    def clear_plan_restriction(security_id, provider:)
      Rails.cache.delete(plan_restriction_cache_key(provider, security_id))
    end

    # Returns the plan restriction info for a security, or nil if none
    # @param security_id [Integer] The security ID
    # @param provider [String] The provider name
    def plan_restriction_for(security_id, provider:)
      Rails.cache.read(plan_restriction_cache_key(provider, security_id))
    end

    # Returns all plan-restricted securities from a collection of security IDs for a provider
    # @param security_ids [Array<Integer>] Security IDs to check
    # @param provider [String] The provider name
    # @return [Hash] security_id => restriction_info
    def plan_restrictions_for(security_ids, provider:)
      return {} if security_ids.blank?

      restrictions = {}
      security_ids.each do |id|
        restriction = plan_restriction_for(id, provider: provider)
        restrictions[id] = restriction if restriction.present?
      end
      restrictions
    end

    # Checks if an error message indicates a plan upgrade is required
    def plan_upgrade_required?(error_message)
      return false if error_message.blank?
      error_message.match?(PLAN_UPGRADE_PATTERN)
    end

    private

      def plan_restriction_cache_key(provider, security_id)
        "#{CACHE_KEY_PREFIX}/#{provider.downcase}/#{security_id}"
      end

      def extract_required_plan(error_message)
        return nil if error_message.blank?
        match = error_message.match(PLAN_UPGRADE_PATTERN)
        match ? match[1] : nil
      end
  end
end
