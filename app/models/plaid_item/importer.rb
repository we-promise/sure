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

    # Every stored account is processed after an import, but only the ones
    # Plaid returned were imported. A liabilities payload left on any other is
    # an earlier sync's, so it is cleared as PlaidAccount::Importer clears its
    # own, rather than processed again as if fresh. The payload is encrypted,
    # so its presence is read in Ruby.
    def clear_liabilities_of_omitted_accounts(snapshot)
      returned = snapshot.accounts.map(&:account_id)
      plaid_item.plaid_accounts.where.not(plaid_id: returned).find_each do |plaid_account|
        plaid_account.upsert_plaid_liabilities_snapshot!({}) if plaid_account.raw_liabilities_payload.present?
      end
    end

    def fetch_and_import_accounts_data
      snapshot = PlaidItem::AccountsSnapshot.new(plaid_item, plaid_provider: plaid_provider)
      returned_ids = snapshot.accounts.map(&:account_id)

      PlaidItem.transaction do
        snapshot.accounts.each do |raw_account|
          plaid_account = plaid_account_for(raw_account, returned_ids: returned_ids)

          PlaidAccount::Importer.new(
            plaid_account,
            account_snapshot: snapshot.get_account_data(raw_account.account_id)
          ).import
        end

        clear_liabilities_of_omitted_accounts(snapshot)

        # Once we know all data has been imported, save the cursor to avoid re-fetching the same data next time
        plaid_item.update!(next_cursor: snapshot.transactions_cursor)
      end
    end

    def plaid_account_for(raw_account, returned_ids:)
      plaid_item.plaid_accounts.find_by(plaid_id: raw_account.account_id) ||
        reissued_plaid_account(raw_account, returned_ids: returned_ids) ||
        plaid_item.plaid_accounts.new(plaid_id: raw_account.account_id)
    end

    # At institutions with tokenized account numbers, such as Chase, re-consenting
    # through update mode can make Plaid issue a new account_id for an account it
    # already shares, while persistent_account_id stays the same. Moving the
    # existing PlaidAccount to the new id keeps it, and the Sure account linked to
    # it, instead of importing the account a second time. Only an account Plaid no
    # longer returns under its old id is taken over. An Item that was already
    # duplicated before this matching existed holds a stale copy next to the one in
    # use, so the most recently updated is preferred. The payload is encrypted, so
    # the match is made in Ruby.
    def reissued_plaid_account(raw_account, returned_ids:)
      persistent_id = raw_account.try(:persistent_account_id).presence
      return unless persistent_id

      candidates = plaid_item.plaid_accounts.where.not(plaid_id: returned_ids).order(updated_at: :desc)
      plaid_account = candidates.detect do |candidate|
        payload = candidate.raw_payload
        payload.is_a?(Hash) && payload["persistent_account_id"] == persistent_id
      end

      plaid_account&.plaid_id = raw_account.account_id
      plaid_account
    end
end
