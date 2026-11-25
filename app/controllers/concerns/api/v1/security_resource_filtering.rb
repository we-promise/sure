# frozen_string_literal: true

# The securities an API caller may see: those held or traded in an account
# they can access. Filtering lives in Security::Search and
# Security::Price::Search.
module Api::V1::SecurityResourceFiltering
  private

    def scoped_security_ids
      Security
        .where(id: holding_security_ids)
        .or(Security.where(id: trade_security_ids))
        .distinct
        .select(:id)
    end

    def holding_security_ids
      Holding.where(account_id: accessible_account_ids).select(:security_id)
    end

    def trade_security_ids
      Trade.joins(:entry).where(entries: { account_id: accessible_account_ids }).select(:security_id)
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.visible.accessible_by(current_resource_owner).select(:id)
    end
end
