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

    assert_equal I18n.t("tags.summary.add"), summary.at_css("[role=tooltip]").text.strip
    assert_empty summary.css("[title]")
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

  test "several tags render full pills and the compact summary for the fit controller" do
    tags = create_tags(3)
    @transaction.update!(tag_ids: tags.map(&:id))

    fit = render_summary.at_css("[data-controller=tag-fit]")

    assert_equal tags.map(&:name), fit.css("[data-tag-fit-target=full] > span > span").map { |node| node.text.strip }
    assert fit.at_css("[data-tag-fit-target=full]").key?("hidden"), "full pills start hidden until measured"
    assert_not fit.at_css("[data-tag-fit-target=compact]").key?("hidden")
  end

  test "more than three tags render two letter badges and an overflow count" do
    tags = create_tags(5)
    @transaction.update!(tag_ids: tags.map(&:id))

    summary = render_summary

    assert_equal 2, summary.css("[aria-describedby] [data-tag-initial]").size
    assert_includes summary.at_css("[aria-describedby]").text, "+3"
    assert_equal 5, summary.css("[data-tag-summary-tooltip] li").size
  end

  test "mobile shows tappable tag pills after the title" do
    tags = create_tags(2)
    @transaction.update!(tag_ids: tags.map(&:id))

    html = Nokogiri::HTML.fragment(render_row)
    line = html.at_css("[data-tag-fit-bounds='0.5']")
    mobile = line.at_css("##{dom_id(@transaction, "tag_summary_mobile")}")

    assert mobile, "mobile tags sit on the title line"
    assert mobile.ancestors("button").any?, "mobile tags open the tag picker"
    assert_equal tags.map(&:name), mobile.css("[data-tag-fit-target=full] > span > span").map { |node| node.text.strip }
  end

  test "untagged rows keep a hidden, empty mobile target for the first tag" do
    @transaction.update!(tag_ids: [])

    html = Nokogiri::HTML.fragment(render_row)
    mobile = html.at_css("##{dom_id(@transaction, "tag_summary_mobile")}")

    assert mobile, "the toggle stream needs a mobile target to replace"
    assert mobile.key?("data-tag-empty")
    assert_nil mobile.at_css("[role=tooltip]"), "no add affordance on touch"
    assert_includes mobile.ancestors("div").map { |node| node["class"].to_s }.join(" "), "has-[[data-tag-empty]]:hidden"
  end

  test "read-only shares get a focusable summary instead of the picker" do
    sign_in_as_family_member
    entry = entries(:transfer_in) # credit card, shared read-only
    entry.transaction.update!(tag_ids: [ tags(:one).id, tags(:two).id ])

    html = Nokogiri::HTML.fragment(render(partial: "transactions/transaction", locals: { entry: entry.reload, balance_trend: nil, view_ctx: "global" }))
    summary = html.at_css("##{dom_id(entry.transaction, "tag_summary_desktop")}")

    assert_nil html.at_css("turbo-frame#tag_dropdown")
    assert summary.at_css("[aria-describedby] [tabindex='0']"), "read-only trigger should be keyboard focusable"
  end

  test "editable rows keep the picker and add no extra tab stop" do
    tags = create_tags(2)
    @transaction.update!(tag_ids: tags.map(&:id))

    html = Nokogiri::HTML.fragment(render_row)

    assert html.at_css("turbo-frame#tag_dropdown")
    assert_nil html.at_css("##{dom_id(@transaction, "tag_summary_desktop")} [tabindex='0']")
  end

  test "transfer rows show read-only tag pills on mobile" do
    outflow_tx = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(
      account: accounts(:depository), entryable: outflow_tx,
      name: "Transfer out", amount: 100, currency: "USD", date: Date.today
    )
    tags = create_tags(2)
    outflow_tx.update!(tag_ids: tags.map(&:id))

    html = Nokogiri::HTML.fragment(render(partial: "transactions/transaction", locals: { entry: outflow_entry.reload, balance_trend: nil, view_ctx: "global" }))
    mobile = html.at_css("##{dom_id(outflow_tx, "tag_summary_mobile")}")

    assert_equal tags.map(&:name), mobile.css("[data-tag-fit-target=full] > span > span").map { |node| node.text.strip }
    assert_empty mobile.ancestors("button")
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

    assert html.at_css("##{dom_id(outflow_tx, "tag_summary_desktop")}")
    assert_nil html.at_css("turbo-frame#tag_dropdown")
    assert_empty html.at_css("##{dom_id(outflow_tx, "tag_summary_desktop")}").text.strip
  end

  private
    def sign_in_as_family_member
      @user = users(:family_member)
      Current.session = Session.create!(user: @user)
      @accessible_account_ids = @user.accessible_accounts.pluck(:id).to_set
    end

    def render_row
      render(partial: "transactions/transaction", locals: { entry: @entry.reload, balance_trend: nil, view_ctx: "global" })
    end

    def render_summary
      Nokogiri::HTML.fragment(render_row).at_css("##{dom_id(@transaction, "tag_summary_desktop")}")
    end

    def create_tags(count)
      Array.new(count) { |i| @family.tags.create!(name: "#{("A".ord + i).chr}lpha tag #{i}", color: Tag::COLORS[i]) }
    end
end
