require "test_helper"

# End-to-end check of the contract between two classes that must agree: the
# Enable Banking processor exposes the counterparty's postal address as
# extra["enable_banking"]["counterparty_address"], and a rule names the
# transaction from it. The processor test and the executor test each cover one
# side in isolation; this exercises the whole path an ING card payment takes.
class EnableBankingEntry::CounterpartyAddressRuleTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "ING test", balance: 1000, currency: "PLN", accountable: Depository.new
    )
    @item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "PL",
      application_id: "test_app_id",
      client_certificate: "test_cert"
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @item,
      name: "ING",
      uid: "eb_uid_ing",
      currency: "PLN"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)
  end

  test "a rule names an ING card payment after the merchant in the creditor address" do
    entry = import_card_payment(merchant: "EXAMPLE MARKET 0042 TESTOWO")

    run_rule(
      conditions: [ additional_detail_condition("counterparty_address") ],
      actions: [ name_from_detail_action("counterparty_address") ]
    )

    entry.reload
    assert_equal "EXAMPLE MARKET 0042 TESTOWO", entry.name
    # The generic card-payment line is preserved in the notes.
    assert_includes entry.notes, "Płatność kartą 01.01.2025"
  end

  test "scoping the rule to the card-payment name leaves an ordinary transfer alone" do
    card = import_card_payment(merchant: "EXAMPLE MARKET 0042 TESTOWO")
    transfer = import_ordinary_transfer(address: "MAIN STREET 12")

    run_rule(
      conditions: [
        additional_detail_condition("counterparty_address"),
        Rule::Condition.new(
          condition_type: "transaction_name", operator: "like", value: "Płatność kartą"
        )
      ],
      actions: [ name_from_detail_action("counterparty_address") ]
    )

    assert_equal "EXAMPLE MARKET 0042 TESTOWO", card.reload.name
    # An ordinary transfer carries an address too, but the name scope keeps the
    # rule from turning a street address into its name.
    assert_equal "Invoice 12345", transfer.reload.name
  end

  test "a locked name is left alone" do
    entry = import_card_payment(merchant: "EXAMPLE MARKET 0042 TESTOWO")
    entry.lock_attr!(:name)

    run_rule(
      conditions: [ additional_detail_condition("counterparty_address") ],
      actions: [ name_from_detail_action("counterparty_address") ]
    )

    assert_equal "Płatność kartą 01.01.2025 Nr karty 1234xx5678", entry.reload.name
  end

  test "a rule below still names a row this action leaves alone" do
    card = import_card_payment(merchant: "EXAMPLE MARKET 0042 TESTOWO")
    # No postal address: the action matches this row but has nothing to copy.
    transfer = import_plain_transfer

    @family.rules.create!(
      name: "Name from counterparty address",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_account", operator: "=", value: @account.id) ],
      actions: [ name_from_detail_action("counterparty_address") ]
    )
    @family.rules.create!(
      name: "Fallback name",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Invoice") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_name", value: "Fallback") ]
    )

    Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "manual").run

    assert_equal "EXAMPLE MARKET 0042 TESTOWO", card.reload.name
    assert_equal "Fallback", transfer.reload.name
  end

  private
    def import_card_payment(merchant:)
      import(
        reference: "ref_ing_card",
        creditor_address: merchant,
        remittance: "Płatność kartą 01.01.2025 Nr karty 1234xx5678"
      )
    end

    def import_ordinary_transfer(address:)
      import(reference: "ref_ordinary_transfer", creditor_address: address, remittance: "Invoice 12345")
    end

    def import_plain_transfer
      tx = {
        entry_reference: "ref_plain_transfer",
        transaction_id: nil,
        booking_date: Date.current.to_s,
        transaction_amount: { amount: "300.00", currency: "PLN" },
        credit_debit_indicator: "DBIT",
        creditor: { name: nil },
        remittance_information: [ "Invoice 12345" ],
        status: "BOOK"
      }

      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
      @account.entries.find_by!(external_id: "enable_banking_ref_plain_transfer")
    end

    def import(reference:, creditor_address:, remittance:)
      tx = {
        entry_reference: reference,
        transaction_id: nil,
        booking_date: Date.current.to_s,
        transaction_amount: { amount: "12.34", currency: "PLN" },
        credit_debit_indicator: "DBIT",
        creditor: { name: nil, postal_address: { address_line: [ creditor_address ] } },
        remittance_information: [ remittance ],
        status: "BOOK"
      }

      EnableBankingEntry::Processor.new(tx, enable_banking_account: @enable_banking_account).process
      @account.entries.find_by!(external_id: "enable_banking_#{reference}")
    end

    def run_rule(conditions:, actions:)
      rule = @family.rules.create!(
        name: "Name from counterparty address",
        resource_type: "transaction",
        active: true,
        conditions: conditions,
        actions: actions
      )
      Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run
      rule
    end

    def additional_detail_condition(value)
      Rule::Condition.new(condition_type: "transaction_additional_detail", operator: "=", value: value)
    end

    def name_from_detail_action(value)
      Rule::Action.new(action_type: "set_transaction_name_from_additional_detail", value: value)
    end
end
