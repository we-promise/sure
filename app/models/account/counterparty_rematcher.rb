# Links already imported transactions to the family's own account whose IBAN
# matches the counterparty, once that IBAN is known. Only the last four
# characters of a counterparty IBAN are stored on a transaction, so the full
# IBAN is read again from the raw rows each Enable Banking account keeps.
class Account::CounterpartyRematcher
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def rematch!
    family.enable_banking_items.includes(enable_banking_accounts: :account).find_each do |item|
      item.enable_banking_accounts.each do |enable_banking_account|
        account = enable_banking_account.current_account
        rows = enable_banking_account.raw_transactions_payload.to_a
        next if account.nil? || rows.empty?

        rematch_account!(account, rows)
      end
    end
  end

  private
    def rematch_account!(account, rows)
      own_account_ids = Account.own_account_ids_by_iban(family, excluding: account)
      external_ids = EnableBankingEntry::Processor.external_ids_for(rows, account: account)

      targets = Hash.new { |hash, key| hash[key] = [] }
      rows.each_with_index do |row, index|
        iban = EnableBankingEntry::Processor.counterparty_account_info(row)[:iban]
        next if iban.blank? || external_ids[index].blank?

        targets[[ iban.last(4), own_account_ids[iban] ]] << external_ids[index]
      end

      targets.each do |(iban_last4, own_account_id), ids|
        entryable_ids = account.entries.where(source: "enable_banking", entryable_type: "Transaction", external_id: ids).select(:entryable_id)
        Transaction.where(id: entryable_ids)
                   .where("counterparty_own_account_id IS DISTINCT FROM ? OR counterparty_iban_last4 IS DISTINCT FROM ?", own_account_id, iban_last4)
                   .update_all(counterparty_iban_last4: iban_last4, counterparty_own_account_id: own_account_id, updated_at: Time.current)
      end
    end
end
