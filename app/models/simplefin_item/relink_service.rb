# frozen_string_literal: true

class SimplefinItem::RelinkService
  Result = Struct.new(
    :results,
    :merge_stats,
    :sfa_stats,
    :unlinked_count,
    keyword_init: true
  )

  # Apply selected relinks by migrating data and moving provider links.
  # Pairs format: [{ sfa_id:, manual_id:, checked: "1" }, ...] (controller already filtered to checked)
  def apply!(simplefin_item:, pairs: [], current_family: nil)
    results = []

    SimplefinItem.transaction do
      pairs.each do |pair|
        sfa = simplefin_item.simplefin_accounts.find_by(id: pair[:sfa_id])
        manual = if current_family
          current_family.accounts.find_by(id: pair[:manual_id])
        else
          Account.find_by(id: pair[:manual_id])
        end
        next unless sfa && manual

        a_new = sfa.current_account
        if a_new.nil?
          ap = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
          a_new = Account.find_by(id: ap&.account_id)
        end

        if a_new && a_new.id == manual.id
          results << { sfa_id: sfa.id, manual_id: manual.id, status: "skipped_same" }
          next
        end

        moved_entries = 0; deleted_entries = 0
        moved_holdings = 0; deleted_holdings = 0

        if a_new
          ap = AccountProvider.find_or_initialize_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
          ap.account = manual
          ap.save!

          if a_new.respond_to?(:entries)
            a_new.entries.find_each do |e|
              if e.external_id.present? && e.source.present? && manual.entries.exists?(external_id: e.external_id, source: e.source)
                e.destroy!
                deleted_entries += 1
              else
                e.update_columns(account_id: manual.id, updated_at: Time.current)
                moved_entries += 1
              end
            end
          end

          if a_new.respond_to?(:holdings)
            a_new.holdings.find_each do |h|
              if manual.holdings.exists?(security_id: h.security_id, date: h.date, currency: h.currency)
                h.destroy!
                deleted_holdings += 1
              else
                h.update_columns(account_id: manual.id, account_provider_id: ap.id, updated_at: Time.current)
                moved_holdings += 1
              end
            end
          end

          manual.update!(simplefin_account_id: sfa.id)
          a_new.destroy!
        else
          ap = AccountProvider.find_or_initialize_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
          ap.account = manual
          ap.save!
          manual.update!(simplefin_account_id: sfa.id)
        end

        results << {
          sfa_id: sfa.id,
          manual_id: manual.id,
          moved_entries: moved_entries,
          deleted_entries: deleted_entries,
          moved_holdings: moved_holdings,
          deleted_holdings: deleted_holdings,
          status: "ok"
        }
      end
    end

    # Final cleanup removed: we no longer auto-merge provider accounts or dedup SFAs here.
    merge_stats = {}
    sfa_stats = {}

    # Recompute unlinked count and clear pending flag when zero
    unlinked_count = 0
    begin
      unlinked_count = simplefin_item.simplefin_accounts
        .left_joins(:account, :account_provider)
        .where(accounts: { id: nil }, account_providers: { id: nil })
        .count
      if unlinked_count.zero? && simplefin_item.respond_to?(:pending_account_setup?) && simplefin_item.pending_account_setup?
        simplefin_item.update!(pending_account_setup: false)
      end
    rescue => e
      Rails.logger.warn("RelinkService: failed to compute unlinked_count: #{e.class} - #{e.message}")
    end

    Result.new(
      results: results,
      merge_stats: merge_stats,
      sfa_stats: sfa_stats,
      unlinked_count: unlinked_count,
    )
  end
end
