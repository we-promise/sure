class SimplefinItem
  # Detects cases where a linked SimpleFIN account looks like it has been
  # replaced by a new unlinked SimpleFIN account at the same institution
  # (typical for credit-card fraud replacement: the bank closes the old card
  # and issues a new one, so SimpleFIN returns both for a transition window).
  #
  # Heuristic:
  #   * dormant_sfa:  linked to a Sure account, no activity in 45+ days,
  #                   AND near-zero current balance.
  #   * active_sfa:   unlinked, recently active (transactions in last 30 days),
  #                   belongs to the same simplefin_item,
  #                   same account_type and same organisation name as dormant_sfa.
  #   * pair:         exactly one active_sfa matches. Two or more candidates
  #                   are considered ambiguous and skipped to avoid a wrong
  #                   auto-suggestion.
  #
  # The detector does NOT mutate any records. It returns a plain array of
  # suggestion hashes which the caller (Importer) persists on sync_stats so
  # the UI can render a prompt.
  class ReplacementDetector
    DORMANCY_DAYS = 45
    ACTIVE_WINDOW_DAYS = 30
    NEAR_ZERO_BALANCE = BigDecimal("1.00")

    # Fraud-replacement is overwhelmingly a credit-card pattern (old card closed,
    # new card issued with same institution/metadata). Checking/savings-account
    # replacement exists but has very different UX cues (e.g., users get a new
    # account number in advance). Scope narrowly for now; broaden later with
    # account-type-aware copy if demand materialises.
    SUPPORTED_ACCOUNT_TYPES = %w[credit credit_card creditcard].freeze

    def initialize(simplefin_item)
      @simplefin_item = simplefin_item
    end

    # @return [Array<Hash>] suggestions. Empty when no replacements detected.
    def call
      sfas = @simplefin_item.simplefin_accounts
                            .includes(:linked_account, :account)
                            .to_a
                            .select { |sfa| supported_type?(sfa) }
      active_unlinked = sfas.select { |sfa| unlinked?(sfa) && active?(sfa) }
      return [] if active_unlinked.empty?

      # First pass: for each dormant candidate, find unambiguous matching actives
      # (exactly one). Rejects "one dormant → many actives" collisions.
      candidates = sfas.filter_map do |dormant|
        next unless linked?(dormant) && dormant_with_zero_balance?(dormant)
        matches = active_unlinked.select { |sfa| same_institution_and_type?(dormant, sfa) }
        next if matches.size != 1
        [ dormant, matches.first ]
      end

      # Second pass: reject "many dormants → one active" collisions. If two
      # dormant accounts both claim the same active, we can't safely auto-suggest
      # either — relinking both would move the provider away from the first.
      active_counts = candidates.each_with_object(Hash.new(0)) { |(_d, a), h| h[a.id] += 1 }
      candidates.filter_map do |dormant, active|
        next if active_counts[active.id] > 1
        build_suggestion(dormant: dormant, active: active)
      end
    end

    private
      def supported_type?(sfa)
        SUPPORTED_ACCOUNT_TYPES.include?(sfa.account_type.to_s.downcase.gsub(/\s+/, "_"))
      end

      def linked?(sfa)
        sfa.current_account.present?
      end

      def unlinked?(sfa)
        sfa.current_account.blank?
      end

      def dormant_with_zero_balance?(sfa)
        # Require evidence of prior activity. An empty payload carries no signal
        # (e.g., a brand-new card just linked) and must not trigger a replacement
        # suggestion. Matches the likely-closed gate used by the setup UI.
        return false if sfa.activity_summary.last_transacted_at.blank?
        return false unless sfa.activity_summary.dormant?(days: DORMANCY_DAYS)
        balance = sfa.current_balance || BigDecimal("0")
        balance.to_d.abs <= NEAR_ZERO_BALANCE
      end

      def active?(sfa)
        sfa.activity_summary.recently_active?(days: ACTIVE_WINDOW_DAYS)
      end

      def same_institution_and_type?(a, b)
        type_matches?(a, b) && org_matches?(a, b)
      end

      def type_matches?(a, b)
        a.account_type.to_s.casecmp?(b.account_type.to_s)
      end

      # Require BOTH sides to have a non-blank org name. SimpleFIN sometimes omits
      # org_data.name; "" casecmp? "" would otherwise treat unrelated accounts as
      # co-institutional, producing false replacement suggestions.
      def org_matches?(a, b)
        name_a = org_name(a)
        name_b = org_name(b)
        return false if name_a.blank? || name_b.blank?
        name_a.casecmp?(name_b)
      end

      def org_name(sfa)
        name = sfa.org_data.is_a?(Hash) ? (sfa.org_data["name"] || sfa.org_data[:name]) : nil
        name.to_s.strip
      end

      def build_suggestion(dormant:, active:)
        {
          "dormant_sfa_id" => dormant.id,
          "active_sfa_id" => active.id,
          "sure_account_id" => dormant.current_account&.id,
          "institution_name" => org_name(dormant),
          "dormant_account_name" => dormant.name,
          "active_account_name" => active.name,
          "confidence" => "high"
        }
      end
  end
end
