class SimplefinConnectionUpdateJob < ApplicationJob
  queue_as :high_priority

  # Disable automatic retries for this job since the setup token is single-use.
  # If the token claim succeeds but import fails, retrying would fail at claim.
  discard_on Provider::Simplefin::SimplefinError do |job, error|
    Rails.logger.error(
      "SimplefinConnectionUpdateJob discarded: #{error.class} - #{error.message} " \
      "(family_id=#{job.arguments.first[:family_id]}, old_item_id=#{job.arguments.first[:old_simplefin_item_id]})"
    )
  end

  def perform(family_id:, old_simplefin_item_id:, setup_token:)
    family = Family.find(family_id)
    old_item = family.simplefin_items.find(old_simplefin_item_id)

    # Step 1: Claim the token and create the new item.
    # This is the critical step - if it fails, we can safely retry.
    # If it succeeds, the token is consumed and we must not retry the claim.
    updated_item = family.create_simplefin_item!(
      setup_token: setup_token,
      item_name: old_item.name
    )

    # Step 2: Import accounts from SimpleFin.
    # If this fails, we have an orphaned item but the token is already consumed.
    # We handle this gracefully by marking the item and continuing.
    begin
      updated_item.import_latest_simplefin_data
    rescue => e
      Rails.logger.error(
        "SimplefinConnectionUpdateJob: import failed for new item #{updated_item.id}: " \
        "#{e.class} - #{e.message}. Item created but may need manual sync."
      )
      # Mark the item as needing attention but don't fail the job entirely.
      # The item exists and can be synced manually later.
      updated_item.update!(status: :requires_update)
      # Still proceed to transfer accounts and schedule old item deletion
    end

    # Step 3: Transfer account links from old to new item.
    # This is idempotent and safe to retry.
    # Check for linked accounts via BOTH legacy FK and AccountProvider.
    ActiveRecord::Base.transaction do
      old_item.simplefin_accounts.includes(:account, account_provider: :account).each do |old_account|
        # Get the linked account via either system
        linked_account = old_account.current_account
        next unless linked_account.present?

        new_simplefin_account = find_matching_simplefin_account(old_account, updated_item.simplefin_accounts)
        next unless new_simplefin_account

        # Update legacy FK
        linked_account.update!(simplefin_account_id: new_simplefin_account.id)

        # Also migrate AccountProvider if it exists
        if old_account.account_provider.present?
          old_account.account_provider.update!(
            provider_type: "SimplefinAccount",
            provider_id: new_simplefin_account.id
          )
        else
          # Create AccountProvider for consistency
          new_simplefin_account.ensure_account_provider!
        end
      end
    end

    # Schedule deletion outside transaction to avoid race condition where
    # the job is enqueued even if the transaction rolls back
    old_item.destroy_later

    # Only mark as good if import succeeded (status wasn't set to requires_update above)
    updated_item.update!(status: :good) unless updated_item.requires_update?
  end

  private
    # Find a matching SimpleFin account in the new item's accounts.
    # Uses a multi-tier matching strategy:
    # 1. Exact account_id match (preferred)
    # 2. Fingerprint match (name + institution + account_type)
    # 3. Fuzzy name match with same institution (fallback)
    def find_matching_simplefin_account(old_account, new_accounts)
      exact_match = new_accounts.find_by(account_id: old_account.account_id)
      return exact_match if exact_match

      old_fingerprint = account_fingerprint(old_account)
      fingerprint_match = new_accounts.find { |new_account| account_fingerprint(new_account) == old_fingerprint }
      return fingerprint_match if fingerprint_match

      old_institution = extract_institution_id(old_account)
      old_name_normalized = normalize_account_name(old_account.name)

      new_accounts.find do |new_account|
        new_institution = extract_institution_id(new_account)
        new_name_normalized = normalize_account_name(new_account.name)

        next false unless old_institution.present? && old_institution == new_institution

        names_similar?(old_name_normalized, new_name_normalized)
      end
    end

    def account_fingerprint(simplefin_account)
      institution_id = extract_institution_id(simplefin_account)
      name_normalized = normalize_account_name(simplefin_account.name)
      account_type = simplefin_account.account_type.to_s.downcase

      "#{institution_id}:#{name_normalized}:#{account_type}"
    end

    def extract_institution_id(simplefin_account)
      org_data = simplefin_account.org_data
      return nil unless org_data.is_a?(Hash)

      org_data["id"] || org_data["domain"] || org_data["name"]&.downcase&.gsub(/\s+/, "_")
    end

    def normalize_account_name(name)
      return "" if name.blank?

      name.to_s
          .downcase
          .gsub(/[^a-z0-9]/, "")
    end

    def names_similar?(name1, name2)
      return false if name1.blank? || name2.blank?

      return true if name1 == name2
      return true if name1.include?(name2) || name2.include?(name1)

      longer = [ name1.length, name2.length ].max
      return false if longer == 0

      # Use Levenshtein distance for more accurate similarity
      distance = levenshtein_distance(name1, name2)
      similarity = 1.0 - (distance.to_f / longer)
      similarity >= 0.8
    end

    # Compute Levenshtein edit distance between two strings
    def levenshtein_distance(s1, s2)
      m, n = s1.length, s2.length
      return n if m.zero?
      return m if n.zero?

      # Use a single array and update in place for memory efficiency
      prev_row = (0..n).to_a
      curr_row = []

      (1..m).each do |i|
        curr_row[0] = i
        (1..n).each do |j|
          cost = s1[i - 1] == s2[j - 1] ? 0 : 1
          curr_row[j] = [
            prev_row[j] + 1,      # deletion
            curr_row[j - 1] + 1,  # insertion
            prev_row[j - 1] + cost # substitution
          ].min
        end
        prev_row, curr_row = curr_row, prev_row
      end

      prev_row[n]
    end
end
