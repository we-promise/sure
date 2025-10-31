# frozen_string_literal: true

module SimplefinItems
  module RelinkHelpers
    extend ActiveSupport::Concern

    NAME_NORM_RE = /\s+/.freeze

    private
      def compute_unlinked_count(item)
        item.simplefin_accounts
            .left_joins(:account, :account_provider)
            .where(accounts: { id: nil }, account_providers: { id: nil })
            .count
      end

      def normalize_name(str)
        s = str.to_s.downcase.strip
        return s if s.empty?
        s.gsub(NAME_NORM_RE, " ")
      end

      def compute_relink_candidates
        # Best-effort dedup before building candidates
        @simplefin_item.dedup_simplefin_accounts! rescue nil

        family = @simplefin_item.family
        manuals = family.accounts.left_joins(:account_providers).where(account_providers: { id: nil }).to_a

        # Evaluate only one SimpleFin account per upstream account_id (prefer linked, else newest)
        grouped = @simplefin_item.simplefin_accounts.group_by(&:account_id)
        sfas = grouped.values.map { |list| list.find { |s| s.current_account.present? } || list.max_by(&:updated_at) }

        Rails.logger.info("SimpleFin compute_relink_candidates: manuals=#{manuals.size} sfas=#{sfas.size} (item_id=#{@simplefin_item.id})")

        pairs = []
        used_manual_ids = []

        sfas.each do |sfa|
          next if sfa.name.blank?
          # Heuristics (with ambiguity guards): last4 > balance ±0.01 > name
          raw = (sfa.raw_payload || {}).with_indifferent_access
          sfa_last4 = raw[:mask] || raw[:last4] || raw[:"last-4"] || raw[:"account_number_last4"]
          sfa_last4 = sfa_last4.to_s.strip.presence
          sfa_balance = (sfa.current_balance || sfa.available_balance).to_d rescue 0.to_d

          chosen = nil
          reason = nil

          # 1) last4 match: compute all candidates not yet used
          if sfa_last4.present?
            last4_matches = manuals.reject { |a| used_manual_ids.include?(a.id) }.select do |a|
              a_last4 = nil
              %i[mask last4 number_last4 account_number_last4].each do |k|
                if a.respond_to?(k)
                  val = a.public_send(k)
                  a_last4 = val.to_s.strip.presence if val.present?
                  break if a_last4
                end
              end
              a_last4.present? && a_last4 == sfa_last4
            end
            # Ambiguity guard: skip if multiple matches
            if last4_matches.size == 1
              cand = last4_matches.first
              begin
                ab = (cand.balance || cand.cash_balance || 0).to_d
                if sfa_balance.nonzero? && ab.nonzero? && (ab - sfa_balance).abs > BigDecimal("1.00")
                  cand = nil
                end
              rescue
              end
              if cand
                chosen = cand
                reason = "last4"
              end
            end
          end

          # 2) balance proximity (within 0.01)
          if chosen.nil? && sfa_balance.nonzero?
            balance_matches = manuals.reject { |a| used_manual_ids.include?(a.id) }.select do |a|
              begin
                ab = (a.balance || a.cash_balance || 0).to_d
                (ab - sfa_balance).abs <= BigDecimal("0.01")
              rescue
                false
              end
            end
            if balance_matches.size == 1
              chosen = balance_matches.first
              reason = "balance"
            end
          end

          # 3) exact normalized name
          if chosen.nil?
            name_matches = manuals.reject { |a| used_manual_ids.include?(a.id) }.select { |a| normalize_name(a.name) == normalize_name(sfa.name) }
            if name_matches.size == 1
              chosen = name_matches.first
              reason = "name"
            end
          end

          if chosen
            used_manual_ids << chosen.id
            pairs << { sfa_id: sfa.id, sfa_name: sfa.name, manual_id: chosen.id, manual_name: chosen.name, reason: reason }
          end
        end

        Rails.logger.info("SimpleFin compute_relink_candidates: built #{pairs.size} pairs (item_id=#{@simplefin_item.id})")

        pairs.map { |p| p.slice(:sfa_id, :sfa_name, :manual_id, :manual_name) }
      end
  end
end
