class Financekit::Export
  def self.for_family(family)
    family.financekit_items.includes(financekit_accounts: [ :account, :financekit_transactions ]).map do |item|
      item.as_json(only: %i[id generation status consent last_device_contact_at last_accepted_at last_imported_at]).merge(
        "accounts" => item.financekit_accounts.map do |source|
          source.as_json(except: %i[financekit_item_id]).merge(
            "account_id" => source.account&.id,
            "transactions" => source.financekit_transactions.as_json(except: %i[financekit_account_id])
          )
        end,
        "receipts" => item.financekit_batches.as_json(only: %i[batch_id generation sequence digest status error_code counts captured_at applied_at created_at])
      )
    end
  end
end
