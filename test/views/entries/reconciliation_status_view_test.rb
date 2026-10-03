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

      doc = Nokogiri::HTML::DocumentFragment.parse(html)

      assert_includes html, "march-statement.pdf"
      assert_includes html, 'role="tooltip"'
      assert_includes html, "DS--tooltip"

      # Parsed rather than regexed: a raw title= would still be a raw title=
      # single-quoted, unquoted, or with the filename HTML-escaped.
      link = doc.at_css("a[href='#{account_statement_path(statement)}']")
      assert link, "expected the statement link"
      assert_nil link["title"], "filename must go through DS::Tooltip, not a title attribute on the link"

      # Scoped to the filename, because DS::Pill renders its own title= for the
      # state tooltip — a blanket "no title anywhere" would fail on that.
      assert_empty doc.css("[title]").select { |el| el["title"] == statement.filename },
        "no element may carry the filename as a raw title attribute"
    end

    # Pins the a11y contract behind `as:`. The tooltip is a SIBLING of the
    # statement link, so DS--tooltip's closest("summary, a") lookup finds no
    # focusable ancestor to borrow focus from. `as: :span` would render a
    # tabindex-less <span> and strand the tooltip for keyboard users; the
    # default `as: :button` keeps a real focusable trigger.
    test "statement filename tooltip keeps a keyboard-reachable trigger" do
      statement = create_statement(filename: "march-statement.pdf")
      entry = create_transaction(account: @account, source: "plaid")
      entry.mark_reconciled!(statement: statement)

      html = render(partial: "entries/reconciliation_status", locals: { entry: entry.reload })
      doc = Nokogiri::HTML::DocumentFragment.parse(html)

      trigger = doc.at_css('[data-controller="DS--tooltip"]')
      assert trigger, "expected a DS::Tooltip wrapper in the reconciled panel"

      assert trigger.at_css("button[type='button']"),
        "tooltip trigger must stay focusable (as: :button) — it has no <a>/<summary> ancestor to borrow focus from"
      assert_empty trigger.ancestors("a"),
        "tooltip must remain a sibling of the statement link, not a descendant of it"
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
