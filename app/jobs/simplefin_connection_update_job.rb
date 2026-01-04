class SimplefinConnectionUpdateJob < ApplicationJob
  queue_as :high_priority

  def perform(family_id:, old_simplefin_item_id:, setup_token:)
    family = Family.find(family_id)
    old_item = family.simplefin_items.find(old_simplefin_item_id)

    updated_item = family.create_simplefin_item!(
      setup_token: setup_token,
      item_name: old_item.name
    )

    # Ensure new SimpleFin accounts exist so we can preserve legacy links.
    updated_item.import_latest_simplefin_data

    ActiveRecord::Base.transaction do
      old_item.simplefin_accounts.each do |old_account|
        next unless old_account.account.present?

        new_account = find_matching_simplefin_account(old_account, updated_item.simplefin_accounts)
        next unless new_account

        old_account.account.update!(simplefin_account_id: new_account.id)
      end

      old_item.destroy_later
    end

    updated_item.update!(status: :good)
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

      common_chars = (name1.chars & name2.chars).length
      similarity = common_chars.to_f / longer
      similarity >= 0.8
    end
end
