require "test_helper"

class Transactions::TagSummaryViewTest < ActionView::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    Current.session = Session.create!(user: @user)

    @accessible_account_ids = @user.accessible_accounts.pluck(:id).to_set
    @split_parent_entry_ids = Set.new

    @entry = entries(:transaction)
    @transaction = @entry.transaction
  end

  test "untagged row renders only the hover add affordance" do
    @transaction.update!(tag_ids: [])

    summary = render_summary

    assert_select summary, "[title=?]", I18n.t("tags.summary.add")
    assert_select summary, "[data-tag-initial]", count: 0
  end

  test "single tag renders as a full pill" do
    tag = create_tags(1).first
    @transaction.update!(tag_ids: [ tag.id ])

    summary = render_summary

    assert_includes summary.at_css("[aria-describedby]").text, tag.name
    assert_select summary, "[aria-describedby] [data-tag-initial]", count: 0
  end

  test "single tag shows its full name on hover" do
    tag = @family.tags.create!(name: "A very long reimbursable business trip tag", color: Tag::COLORS.first)
    @transaction.update!(tag_ids: [ tag.id ])

    summary = render_summary

    assert_equal [ tag.name ], summary.css("[data-tag-summary-tooltip] li span.truncate").map { |node| node.text.strip }
    assert_empty summary.css("[aria-describedby] [title]").map { |node| node["title"] }.reject(&:blank?)
  end

  test "two or three tags render as letter badges with every tag in the tooltip" do
    tags = create_tags(3)
    @transaction.update!(tag_ids: tags.map(&:id))

    summary = render_summary
    tooltip = summary.at_css("[role=tooltip]")

    assert_equal 3, summary.css("[aria-describedby] [data-tag-initial]").size
    assert_equal tags.map { |tag| tag.name.first }, summary.css("[aria-describedby] [data-tag-initial]").map { |node| node.text.strip }
    assert_not_includes summary.at_css("[aria-describedby]").text, "+"
    assert_equal tags.map(&:name), tooltip.css("[data-tag-summary-tooltip] li span.truncate").map { |node| node.text.strip }
  end

  test "more than three tags render two letter badges and an overflow count" do
    tags = create_tags(5)
    @transaction.update!(tag_ids: tags.map(&:id))

    summary = render_summary

    assert_equal 2, summary.css("[aria-describedby] [data-tag-initial]").size
    assert_includes summary.at_css("[aria-describedby]").text, "+3"
    assert_equal 5, summary.css("[data-tag-summary-tooltip] li").size
  end

  test "mobile line lists tag names comma separated" do
    tags = create_tags(2)
    @transaction.update!(tag_ids: tags.map(&:id))

    html = Nokogiri::HTML.fragment(render_row)
    mobile = html.at_css("##{dom_id(@transaction, :tag_names_mobile)}")

    assert_includes mobile.text, tags.map(&:name).join(", ")
  end

  test "transfer rows render tags read-only" do
    outflow_tx = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(
      account: accounts(:depository), entryable: outflow_tx,
      name: "Transfer out", amount: 100, currency: "USD", date: Date.today
    )
    inflow_tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(
      account: accounts(:credit_card), entryable: inflow_tx,
      name: "Transfer in", amount: -100, currency: "USD", date: Date.today
    )
    Transfer.create!(inflow_transaction: inflow_tx, outflow_transaction: outflow_tx, status: "confirmed")

    html = Nokogiri::HTML.fragment(render(partial: "transactions/transaction", locals: { entry: outflow_entry, balance_trend: nil, view_ctx: "global" }))

    assert html.at_css("##{dom_id(outflow_tx, :tag_summary)}")
    assert_nil html.at_css("turbo-frame#tag_dropdown")
    assert_empty html.at_css("##{dom_id(outflow_tx, :tag_summary)}").text.strip
  end

  private
    def render_row
      render(partial: "transactions/transaction", locals: { entry: @entry.reload, balance_trend: nil, view_ctx: "global" })
    end

    def render_summary
      Nokogiri::HTML.fragment(render_row).at_css("##{dom_id(@transaction, :tag_summary)}")
    end

    def create_tags(count)
      Array.new(count) { |i| @family.tags.create!(name: "#{("A".ord + i).chr}lpha tag #{i}", color: Tag::COLORS[i]) }
    end
end
