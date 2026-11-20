require "test_helper"

class Portfolio::SectionRegistryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.last_30_days
    @as_of = Date.current
    @statement = InvestmentStatement.new(@family, user: @user)
  end

  test "registers the built-in sections with their partials and locals" do
    sections = registry.sections

    assert_equal Portfolio::SectionRegistry::KEYS, sections.map { |s| s[:key] }
    assert_equal %w[portfolios/holdings portfolios/accounts], sections.map { |s| s[:partial] }
    assert sections.all? { |s| s[:collapsible] }

    # Every partial gets its locals passed in: none of them reaches for
    # Date.current or Current.family on its own.
    sections.each do |section|
      assert_equal({ statement: @statement, period: @period, as_of: @as_of }, section[:locals].slice(:statement, :period, :as_of),
        "#{section[:key]} must receive the shared locals rather than reading them itself")
    end
  end

  test "the accounts section is visible only when the family has investment accounts" do
    assert registry.sections.find { |s| s[:key] == "accounts" }[:visible]

    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    assert_not empty.find { |s| s[:key] == "accounts" }[:visible]
  end

  # Created in reverse name order, so the cards come back by name only if the
  # query asks for it.
  test "the accounts section lists the cards in name order" do
    zeta = @family.accounts.create!(name: "Zeta brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    alpha = @family.accounts.create!(name: "Alpha brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_includes cards, zeta
    assert_operator cards.index(alpha), :<, cards.index(zeta)
    assert_equal @statement.investment_accounts.to_a.sort_by(&:id), cards.sort_by(&:id),
      "the cards must be exactly the statement's investment accounts"
  end

  # The cards are the statement's own records, so the associations their
  # logos read have to be preloaded onto those records, not left to load per
  # card.
  test "the account cards come with everything their logos read preloaded" do
    logoed = accounts(:investment)
    logoed.logo.attach(io: StringIO.new("logo"), filename: "logo.png", content_type: "image/png")
    provider = LunchflowAccount.create!(lunchflow_item: lunchflow_items(:one), account_id: "lf_registry_logo",
                                        name: logoed.name, currency: "USD")
    AccountProvider.create!(account: logoed, provider: provider)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_not_empty cards
    cards.each do |account|
      %i[logo_attachment accountable plaid_account simplefin_account account_providers].each do |name|
        assert account.association(name).loaded?, "#{name} is not preloaded on #{account.name}"
      end
    end
    card = cards.find { |account| account.id == logoed.id }
    assert card.logo_attachment.association(:blob).loaded?, "the logo's blob is not preloaded"
    assert_not_empty card.account_providers
    card.account_providers.each do |link|
      assert link.association(:provider).loaded?, "the provider link's provider is not preloaded"
    end
  end

  test "the account cards ignore case when ordering by name" do
    lower = @family.accounts.create!(name: "alpha brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    upper = @family.accounts.create!(name: "Beta brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_operator cards.index(lower), :<, cards.index(upper)
  end

  # The cards keep the order the rest of the app lists accounts in (the
  # database's collation, as Account.alphabetically uses), where an accented
  # name sits with its letter rather than after "z".
  test "the account cards follow the database's name order" do
    names = [ "Zebra brokerage", "Épargne", "Fidelity" ]
    accounts = names.map do |name|
      @family.accounts.create!(name: name, balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    end
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    expected = @family.accounts.where(id: accounts.map(&:id)).alphabetically.map(&:name)
    assert_equal [ "Épargne", "Fidelity", "Zebra brokerage" ], expected, "precondition: the database collation places É with E"
    assert_equal expected, cards.select { |card| names.include?(card.name) }.map(&:name)
  end

  # The statement's query has no order of its own, so the tiebreak must not
  # lean on whatever order its rows arrive in: feed them in descending id.
  test "account cards with the same name are ordered by id whatever order the statement returns" do
    same = %w[b d f].map do |digit|
      @family.accounts.create!(id: "#{digit * 8}-0000-4000-8000-000000000000", name: "Same brokerage", balance: 100,
                               currency: "USD", accountable: Investment.new, owner: @user)
    end
    @statement.stubs(:investment_accounts).returns(@family.accounts.where(id: same.map(&:id)).order(id: :desc))

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_equal same.map(&:id), cards.map(&:id)
  end

  test "orders sections by the user's saved order, appending anything it omits" do
    @user.update_section_preferences("portfolio", order: %w[stub])

    assert_equal %w[stub holdings accounts], registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }
  end

  test "a saved order that repeats a key renders that section once" do
    @user.update_section_preferences("portfolio", order: %w[stub accounts stub])

    keys = registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }

    assert_equal %w[stub accounts holdings], keys
  end

  test "ignores keys in the saved order that no longer exist" do
    @user.update_section_preferences("portfolio", order: %w[gone accounts])

    assert_equal %w[accounts holdings], registry.sections.map { |s| s[:key] }
  end

  test "appends extra sections after the built-ins" do
    sections = registry(extra_sections: [ stub_section ]).sections

    assert_equal %w[holdings accounts stub], sections.map { |s| s[:key] }
  end

  # A family whose investment accounts hold nothing has no rows to list, so
  # the section stays out rather than drawing an empty table.
  test "the holdings section is visible only when the family holds a security" do
    assert registry.sections.find { |s| s[:key] == "holdings" }[:visible]

    Holding.where(account: @statement.investment_accounts).delete_all
    @statement = InvestmentStatement.new(@family, user: @user)
    sections = registry.sections

    assert_not sections.find { |s| s[:key] == "holdings" }[:visible]
    assert sections.find { |s| s[:key] == "accounts" }[:visible], "the accounts still list with nothing held"
  end

  # The statement falls back on its own for an unknown sort, so the view must
  # be told what it fell back to, or no header shows the sort it sees.
  test "passes the effective sort and direction to the holdings locals" do
    holdings = Portfolio::SectionRegistry.new(
      statement: @statement, period: @period, as_of: @as_of, user: @user, sort: "unsupported", dir: "asc"
    ).sections.find { |s| s[:key] == "holdings" }

    assert_equal [ "value", "asc" ], [ holdings[:locals][:sort], holdings[:locals][:dir] ]
    values = holdings[:locals][:rows].map { |row| row.amount.amount }
    assert_equal values.sort, values, "the rows are in the order the locals name"
  end

  test "passes the sort and direction through to the holdings locals" do
    # Ticker order and name order disagree for this one: it sorts last by
    # ticker and first by name, so a name sort that secretly ordered by
    # ticker would put it in the wrong place.
    zebra = Security.create!(ticker: "ZZZA", name: "Aardvark Holdings")
    Holding.create!(
      account: accounts(:investment), security: zebra, date: Date.current,
      qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true
    )

    holdings = Portfolio::SectionRegistry.new(
      statement: @statement, period: @period, as_of: @as_of, user: @user, sort: "name", dir: "asc"
    ).sections.find { |s| s[:key] == "holdings" }

    assert_equal "name", holdings[:locals][:sort]
    assert_equal "asc", holdings[:locals][:dir]
    rows = holdings[:locals][:rows]
    names = rows.map { |row| row.name.downcase }
    assert_equal names.sort, names, "sort: \"name\" must order by security name, not ticker"
    assert_equal "ZZZA", rows.first.ticker, "the name sort must put Aardvark first despite its ticker"
  end

  private
    def stub_section
      { key: "stub", title: "portfolios.sections.accounts", partial: "portfolios/accounts",
        locals: {}, visible: true, collapsible: true }
    end

    def registry(extra_sections: [])
      Portfolio::SectionRegistry.new(
        statement: @statement,
        period: @period,
        as_of: @as_of,
        user: @user,
        extra_sections: extra_sections
      )
    end
end
