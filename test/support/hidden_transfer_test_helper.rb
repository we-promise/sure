module HiddenTransferTestHelper
  # A transfer from +from+ (Checking, which family_member can open) into a new
  # account only family_admin can open, with the names Sure gives its legs and
  # fee: "Transfer to Hidden Savings", "Transfer fee — Transfer to Hidden Savings".
  def create_transfer_to_hidden_account(name: "Hidden Savings", accountable: Depository.new, from: accounts(:depository),
                                        date: Date.current, amount: 100, source_fee_amount: nil)
    family = from.family
    hidden = family.accounts.create!(name: name, owner: users(:family_admin), balance: 0, currency: "USD", accountable: accountable)

    Transfer::Creator.new(
      family: family, source_account_id: from.id, destination_account_id: hidden.id,
      date: date, amount: amount, source_fee_amount: source_fee_amount
    ).create
  end

  # The entry of such a transfer's 2 USD fee: "Transfer fee — Transfer to Hidden Savings".
  def create_transfer_fee_to_hidden_account
    create_transfer_to_hidden_account(source_fee_amount: 2).fee_transactions.sole.entry
  end
end
