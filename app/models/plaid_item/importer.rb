class PlaidItem::Importer
  def initialize(plaid_item, plaid_provider:)
    @plaid_item = plaid_item
    @plaid_provider = plaid_provider
  end

  def import
    fetch_and_import_item_data
    fetch_and_import_accounts_data
    plaid_item.good! if plaid_item.requires_update?
  rescue Plaid::ApiError => e
    handle_plaid_error(e)
  end

  private
    attr_reader :plaid_item, :plaid_provider

    # All errors that should halt the import should be re-raised after handling
    # These errors will propagate up to the Sync record and mark it as failed.
    def handle_plaid_error(error)
      error_body = JSON.parse(error.response_body)

      case error_body["error_code"]
      when "ITEM_LOGIN_REQUIRED"
        plaid_item.update!(status: :requires_update)
      else
        raise error
      end
    end

    def fetch_and_import_item_data
      item_data = plaid_provider.get_item(plaid_item.access_token).item
      institution_data = plaid_provider.get_institution(item_data.institution_id).institution

      plaid_item.upsert_plaid_snapshot!(item_data)
      plaid_item.upsert_plaid_institution_snapshot!(institution_data)
    end

    def fetch_and_import_accounts_data
      snapshot = PlaidItem::AccountsSnapshot.new(plaid_item, plaid_provider: plaid_provider)

      PlaidItem.transaction do
        snapshot.accounts.each do |raw_account|
          plaid_account = plaid_item.plaid_accounts.find_or_initialize_by(
            plaid_id: raw_account.account_id
          )

          PlaidAccount::Importer.new(
            plaid_account,
            account_snapshot: snapshot.get_account_data(raw_account.account_id)
          ).import
        end

        # Once we know all data has been imported, save the cursor to avoid re-fetching the same data next time
        plaid_item.update!(next_cursor: snapshot.transactions_cursor)

        # Clear the replay marker only if the database still holds the exact
        # request this fetch served, which has to be decided in the WHERE clause.
        # Comparing plaid_item.replay_requested_at would compare stale memory:
        # the record was loaded before the sync started, so a replay requested
        # since then is invisible here and would be cleared without ever running.
        consumed_at = plaid_item.replay_pending? ? snapshot.replay_consumed_at : nil
        if consumed_at.present?
          PlaidItem
            .where(id: plaid_item.id, replay_requested_at: consumed_at)
            .update_all(replay_requested_at: nil, updated_at: Time.current)
        end
      end
    end
end
