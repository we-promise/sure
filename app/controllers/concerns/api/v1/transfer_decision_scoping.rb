# frozen_string_literal: true

# Transfers and rejected transfers the caller may read (both legs on an account
# they can access), and the Transfer::Search over them both indexes share.
module Api::V1::TransferDecisionScoping
  extend ActiveSupport::Concern

  private

    def transfer_decision_scope(model_class)
      model_class
        .where(
          inflow_transaction_id: accessible_transaction_ids,
          outflow_transaction_id: accessible_transaction_ids
        )
        .includes(
          inflow_transaction: { entry: :account },
          outflow_transaction: { entry: :account }
        )
    end

    # `status` applies to transfers only; rejected transfers have none.
    def transfer_decision_search(scope, status: nil)
      Transfer::Search.new(
        scope,
        filters: {
          status:,
          account_id: uuid_filter_param(:account_id),
          start_date: date_filter_param(:start_date),
          end_date: date_filter_param(:end_date)
        }
      )
    end

    def accessible_transaction_ids
      Transaction
        .joins(:entry)
        .where(entries: { account_id: accessible_account_ids })
        .select(:id)
    end

    def accessible_account_ids
      @accessible_account_ids ||= Current.family.accounts.accessible_by(Current.user).select(:id)
    end
end
