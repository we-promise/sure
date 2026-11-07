class PlaidItem::Importer
  def initialize(plaid_item, plaid_provider:)
    @plaid_item = plaid_item
    @plaid_provider = plaid_provider
  end

  def import
    fetch_and_import_item_data
    warnings = fetch_and_import_accounts_data
    plaid_item.good! if plaid_item.requires_update?
    warnings
  rescue Plaid::ApiError => e
    handle_plaid_error(e)
    # The handled login error preserves the existing reconnect behavior, but
    # update!'s Boolean must not be interpreted as a data-quality warning.
    []
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

      snapshot.warnings
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
    # longer returns under its old id is taken over. The payload is encrypted, so
    # the match is made in Ruby.
    #
    # An Item duplicated before this matching existed holds stale copies next to
    # the one in use. A copy linked to a Sure account is preferred, then the most
    # recently created, which is the one Plaid moved to last. updated_at cannot
    # tell them apart, because clearing an omitted copy's liabilities updates it.
    def reissued_plaid_account(raw_account, returned_ids:)
      persistent_id = raw_account.try(:persistent_account_id).presence
      return unless persistent_id

      candidates = omitted_accounts(returned_ids)
      matches = candidates.select { |_, candidate_persistent_id| candidate_persistent_id == persistent_id }.keys
      plaid_account = matches.max_by { |candidate| [ candidate.current_account ? 1 : 0, candidate.created_at ] }
      return unless plaid_account

      candidates.delete(plaid_account)
      plaid_account.plaid_id = raw_account.account_id
      plaid_account
    end

    # The accounts Plaid did not return in this import, each with its
    # persistent_account_id. They are loaded and their payloads decrypted once,
    # when the first unknown account_id needs them, so an unreadable payload is
    # logged once. An account is removed once it has been taken over.
    def omitted_accounts(returned_ids)
      @omitted_accounts ||= plaid_item.plaid_accounts.where.not(plaid_id: returned_ids).to_h do |plaid_account|
        [ plaid_account, persistent_account_id_of(plaid_account) ]
      end
    end

    # A payload that cannot be decrypted is left unmatched, so the account is
    # imported as it was before this matching rather than failing the import.
    def persistent_account_id_of(plaid_account)
      payload = plaid_account.raw_payload
      payload["persistent_account_id"] if payload.is_a?(Hash)
    rescue ActiveRecord::Encryption::Errors::Decryption
      log_unreadable_payload(plaid_account)
      nil
    end

    def log_unreadable_payload(plaid_account)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Skipped a Plaid account with an unreadable payload when matching a reissued account_id",
        source: self.class.name,
        provider_key: "plaid",
        family: plaid_item.family,
        account: plaid_account.current_account,
        account_provider: plaid_account.account_provider,
        metadata: {
          plaid_item_id: plaid_item.id,
          plaid_account_id: plaid_account.id
        }
      )
    end
end
