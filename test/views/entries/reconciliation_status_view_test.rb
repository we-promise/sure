require "test_helper"

module Entries
  class ReconciliationStatusViewTest < ActionView::TestCase
    include EntriesTestHelper
    include EntriesHelper

    setup do
      @account = accounts(:depository)
    end

    test "shows uncleared state for a manual entry" do
      entry = create_transaction(account: @account)

      html = render(partial: "entries/reconciliation_status", locals: { entry: entry })

      assert_includes html, I18n.t("entries.reconciliation.states.uncleared")
      assert_includes html, I18n.t("entries.reconciliation.descriptions.uncleared")
      assert_not_includes html, I18n.t("entries.reconciliation.statement_label")
    end

    test "shows cleared state for a provider-sourced entry" do
      entry = create_transaction(account: @account, source: "plaid")

      html = render(partial: "entries/reconciliation_status", locals: { entry: entry })

      assert_includes html, I18n.t("entries.reconciliation.states.cleared")
      assert_includes html, I18n.t("entries.reconciliation.descriptions.cleared")
    end

    test "shows reconciled state with statement link" do
      statement = create_statement
      entry = create_transaction(account: @account, source: "plaid")
      entry.mark_reconciled!(statement: statement)

      html = render(partial: "entries/reconciliation_status", locals: { entry: entry.reload })

      assert_includes html, I18n.t("entries.reconciliation.states.reconciled")
      assert_includes html, account_statement_path(statement)
      assert_includes html, entry_reconciliation_statement_label(statement)
    end

    test "surfaces the statement filename through DS::Tooltip, not a raw title attribute" do
      statement = create_statement(filename: "march-statement.pdf")
      entry = create_transaction(account: @account, source: "plaid")
      entry.mark_reconciled!(statement: statement)

      html = render(partial: "entries/reconciliation_status", locals: { entry: entry.reload })

      assert_includes html, "march-statement.pdf"
      assert_includes html, 'role="tooltip"'
      assert_includes html, "DS--tooltip"
      assert_no_match(/title="march-statement\.pdf"/, html)
    end

    test "shows reconciled without statement when evidence was removed" do
      statement = create_statement
      entry = create_transaction(account: @account)
      entry.mark_reconciled!(statement: statement)
      statement.destroy!
      entry.reload

      html = render(partial: "entries/reconciliation_status", locals: { entry: entry })

      assert_includes html, I18n.t("entries.reconciliation.states.reconciled")
      assert_includes html, I18n.t("entries.reconciliation.no_statement")
    end

    test "ledger row shows reconciled pill only when reconciled" do
      entry = create_transaction(account: @account, source: "plaid")
      entry.mark_reconciled!

      html = render(partial: "transactions/transaction", locals: { entry: entry, balance_trend: nil, view_ctx: "global" })

      assert_includes html, I18n.t("transactions.transaction.reconciled")
    end

    test "ledger row does not show a cleared badge" do
      entry = create_transaction(account: @account, source: "plaid")

      html = render(partial: "transactions/transaction", locals: { entry: entry, balance_trend: nil, view_ctx: "global" })

      assert_not_includes html, I18n.t("entries.reconciliation.states.cleared")
      assert_not_includes html, I18n.t("transactions.transaction.reconciled")
    end

    private
      def create_statement(account: @account, filename: "statement.pdf")
        AccountStatement.create_from_upload!(
          family: account.family,
          account: account,
          file: uploaded_file(
            filename: filename,
            content_type: "application/pdf",
            content: file_fixture("imports/sample_bank_statement.pdf").binread
          )
        )
      end
  end
end
