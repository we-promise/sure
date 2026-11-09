require "test_helper"

class BalanceSheet::AccountGroupTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  def create_account(name, balance:, currency: @family.currency, institution: nil, domain: nil, accountable: Depository.new, owner: nil, logo: nil)
    @family.accounts.create!(name: name, balance: balance, currency: currency, institution_name: institution, institution_domain: domain,
                             accountable: accountable, owner: owner).tap do |account|
      account.logo.attach(io: file_fixture(logo).open, filename: "#{name}.png", content_type: "image/png") if logo
    end
  end

  def cash_group
    BalanceSheet.new(@family).assets.account_groups.find { |group| group.key == "depository" }
  end

  def user_cash_group(user)
    BalanceSheet.new(@family, user: user).assets.account_groups.find { |group| group.key == "depository" }
  end

  test "accounts sharing an institution become one entry with their combined total in the family's currency" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 2)
    create_account("Wise EUR", balance: 100, currency: "EUR", institution: "Wise", domain: "wise.com")
    create_account("Wise main", balance: 50, institution: "Wise", domain: "wise.com")
    create_account("Savings", balance: 10)

    entries = cash_group.sidebar_entries
    bundle = entries.find { |entry| entry.is_a?(BalanceSheet::AccountGroup::InstitutionBundle) }

    assert_equal 2, entries.size
    assert_equal [ "Wise", %w[Wise\ EUR Wise\ main] ], [ bundle.name, bundle.accounts.map(&:name).sort ]
    assert_equal Money.new(250, @family.currency), bundle.total_money
  end

  test "accounts at one institution sharing a currency show their total in that currency" do
    ExchangeRate.create!(from_currency: "SGD", to_currency: @family.currency, date: Date.current, rate: 3)
    create_account("DBS savings", balance: 100, currency: "SGD", institution: "DBS")
    create_account("DBS salary", balance: 20, currency: "SGD", institution: "DBS")

    bundle = cash_group.sidebar_entries.grep(BalanceSheet::AccountGroup::InstitutionBundle).sole

    assert_equal Money.new(120, "SGD"), bundle.total_money
  end

  test "with a name order a bundle sorts by its institution's name, its accounts keeping theirs" do
    create_account("Apple", balance: 1)
    create_account("Zeta EUR", balance: 1, institution: "Monzo")
    create_account("Alpha GBP", balance: 1, institution: "Monzo")
    create_account("Pear", balance: 1)

    entries = cash_group.sidebar_entries(order: AccountOrder.new("name_asc"))

    assert_equal %w[Apple Monzo Pear], entries.map(&:name)
    assert_equal [ "Alpha GBP", "Zeta EUR" ], entries[1].accounts.map(&:name)
    assert_equal %w[Pear Monzo Apple], cash_group.sidebar_entries(order: AccountOrder.new("name_desc")).map(&:name)
  end

  test "with a balance order a bundle sorts by its total in the family's currency" do
    create_account("Big", balance: 50)
    create_account("Wise A", balance: 30, institution: "Wise")
    create_account("Wise B", balance: 40, institution: "Wise")
    create_account("Small", balance: 10)

    assert_equal %w[Wise Big Small], cash_group.sidebar_entries(order: AccountOrder.new("balance_desc")).map(&:name)
    assert_equal %w[Small Big Wise], cash_group.sidebar_entries(order: AccountOrder.new("balance_asc")).map(&:name)
  end

  test "an institution with a single account stays a plain row" do
    create_account("Schwab", balance: 10, institution: "Schwab")
    create_account("Savings", balance: 10)

    assert cash_group.sidebar_entries.none? { |entry| entry.is_a?(BalanceSheet::AccountGroup::InstitutionBundle) }
  end

  test "accounts group only when their institution name and URL both match" do
    create_account("A", balance: 1, institution: " wise ", domain: "wise.com")
    create_account("B", balance: 1, institution: "WISE", domain: "https://www.wise.com/")
    create_account("Same name, other URL", balance: 1, institution: "Wise", domain: "wise.co.uk")
    create_account("Same URL, other name", balance: 1, institution: "Revolut", domain: "wise.com")
    create_account("No institution", balance: 1)
    create_account("No institution either", balance: 1)
    create_account("C", balance: 1, domain: "dbs.com.sg")
    create_account("D", balance: 1, domain: "dbs.com.sg")

    bundles = cash_group.sidebar_entries.grep(BalanceSheet::AccountGroup::InstitutionBundle)

    assert_equal [ %w[A B], %w[C D] ], bundles.map { |bundle| bundle.accounts.map(&:name).sort }.sort
    assert_equal [ "wise|wise.com", "|dbs.com.sg" ], bundles.map(&:key).sort
  end

  test "saved settings rename a bundle and show its total in their currency, converted at today's rates" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "CHF", date: Date.current, rate: 0.8)
    ExchangeRate.create!(from_currency: @family.currency, to_currency: "CHF", date: Date.current, rate: 0.5)
    create_account("Wise EUR", balance: 100, currency: "EUR", institution: "Wise")
    create_account("Wise main", balance: 50, institution: "Wise")
    settings = @family.institution_groups.create!(key: "wise|", name: "Wise multi-currency", currency: "CHF")

    bundle = cash_group.sidebar_entries(institution_groups: { "wise|" => settings }).grep(BalanceSheet::AccountGroup::InstitutionBundle).sole

    assert_equal "Wise multi-currency", bundle.name
    assert_equal Money.new(105, "CHF"), bundle.total_money
  end

  test "a saved currency in the family's converts accounts sharing another currency" do
    ExchangeRate.create!(from_currency: "SGD", to_currency: @family.currency, date: Date.current, rate: 3)
    create_account("DBS savings", balance: 100, currency: "SGD", institution: "DBS")
    create_account("DBS salary", balance: 20, currency: "SGD", institution: "DBS")
    settings = @family.institution_groups.create!(key: "dbs|", currency: @family.currency)

    bundle = cash_group.institution_bundles(institution_groups: { "dbs|" => settings }).sole

    assert_equal Money.new(360, @family.currency), bundle.total_money
    assert_equal "DBS", bundle.name
  end

  test "a bundle of linked investment accounts draws the history their providers support together" do
    %w[Alpha Beta].each { |name| create_account(name, balance: 1, institution: "etoro", domain: "etoro.com", accountable: Investment.new) }
    bundle = BalanceSheet.new(@family).assets.account_groups.find { |group| group.key == "investment" }.institution_bundles.sole
    series = Series.new(start_date: 30.days.ago.to_date, end_date: Date.current, interval: "1 day", values: [])

    Balance::LinkedInvestmentSeriesNormalizer.expects(:aggregate_account_ids).never
    bundle.balance_series(period: Period.last_30_days)

    Account.any_instance.stubs(:linked?).returns(true)
    Balance::LinkedInvestmentSeriesNormalizer.unstub(:aggregate_account_ids)
    Balance::LinkedInvestmentSeriesNormalizer.expects(:aggregate_account_ids)
      .with(has_entries(account_ids: bundle.accounts.map(&:id), currency: bundle.currency))
      .returns(series)
    assert_equal series, bundle.balance_series(period: Period.last_30_days)
  end

  test "looking a bundle up by its slug builds that bundle alone" do
    %w[Alpha Beta].each { |name| create_account(name, balance: 1, institution: "wise", domain: "wise.com") }
    %w[Gamma Delta].each { |name| create_account(name, balance: 1, institution: "revolut", domain: "revolut.com") }
    slug = cash_group.institution_bundles.find { |bundle| bundle.key == "revolut|revolut.com" }.slug
    @family.institution_groups.delete_all

    InstitutionGroup.expects(:form).once.with("revolut|revolut.com", anything).returns(nil)
    bundle = BalanceSheet.new(@family).institution_bundle(slug)

    assert_equal %w[Delta Gamma], bundle.accounts.map { |account| account.account.name }.sort
    assert_nil BalanceSheet.new(@family).institution_bundle("depository-000000000000")
  end

  test "a bundle's sparkline version changes when a shared account leaves the viewer's finances" do
    owner = users(:empty)
    member = users(:sso_only)
    alpha = create_account("Alpha", balance: 1, institution: "wise", domain: "wise.com", owner: owner)
    beta = create_account("Beta", balance: 5, institution: "wise", domain: "wise.com", owner: owner)
    [ alpha, beta ].each { |account| account.share_with!(member, include_in_finances: true) }

    before = user_cash_group(member).institution_bundles.sole.sparkline_version
    beta.account_shares.find_by!(user: member).update!(include_in_finances: false)

    assert_not_equal before, user_cash_group(member).institution_bundles.sole.sparkline_version
  end

  test "a group forms with the name, URL and icon of its first account in the user's Default Account Order" do
    user = users(:empty)
    alpha = create_account("Alpha", balance: 1, institution: "wise", domain: "wise.com", owner: user, logo: "profile_image.png")
    beta = create_account("Beta", balance: 5, institution: "WISE", domain: "wise.com", owner: user, logo: "square-placeholder.png")
    user.update!(default_account_order: "name_desc")

    bundle = user_cash_group(user).institution_bundles.sole

    assert_equal [ beta, "WISE", "WISE", "wise.com" ], [ bundle.lead_account.account, bundle.name, bundle.inherited_name, bundle.inherited_domain ]
    group = @family.institution_groups.sole
    assert_equal [ "wise|wise.com", beta.logo.blob ], [ group.key, group.logo.blob ]
    assert_equal beta.stored_logo_url, bundle.logo_url
    assert_equal alpha.logo.blob, alpha.reload.logo.blob, "forming the group changes no account's icon"
  end

  test "changing the Default Account Order before a group forms changes which account it takes its icon from" do
    user = users(:empty)
    create_account("Alpha Wise", balance: 1, institution: "Wise", domain: "wise.com", owner: user, logo: "profile_image.png")
    create_account("Beta Wise", balance: 5, institution: "Wise", domain: "wise.com", owner: user, logo: "square-placeholder.png")
    user.update!(default_account_order: "name_asc")
    user_cash_group(user).institution_bundles

    create_account("Alpha DBS", balance: 1, institution: "DBS", owner: user, logo: "profile_image.png")
    beta_dbs = create_account("Beta DBS", balance: 5, institution: "DBS", owner: user, logo: "square-placeholder.png")
    user.update!(default_account_order: "balance_desc")
    bundles = user_cash_group(user.reload).institution_bundles.index_by(&:key)

    assert_equal beta_dbs.logo.blob, @family.institution_groups.find_by!(key: "dbs|").logo.blob
    assert_equal beta_dbs.stored_logo_url, bundles["dbs|"].logo_url
    wise = @family.institution_groups.find_by!(key: "wise|wise.com")
    assert_equal "Alpha Wise.png", wise.logo.blob.filename.to_s, "the group formed earlier keeps the icon it took then"
  end

  test "an account joining a formed group keeps its own icon, and the group its icon, even when it sorts first" do
    user = users(:empty)
    alpha = create_account("Beta", balance: 1, institution: "Wise", domain: "wise.com", owner: user, logo: "profile_image.png")
    create_account("Gamma", balance: 1, institution: "Wise", domain: "wise.com", owner: user)
    user.update!(default_account_order: "name_asc")
    group_logo = alpha.logo.blob
    user_cash_group(user).institution_bundles

    newcomer = create_account("Aardvark", balance: 1, institution: "Wise", domain: "wise.com", owner: user, logo: "square-placeholder.png")
    bundle = user_cash_group(user.reload).institution_bundles.sole

    assert_equal newcomer, bundle.lead_account.account
    assert_equal 3, bundle.accounts.size
    assert_equal group_logo, @family.institution_groups.sole.logo.blob
    assert_equal alpha.reload.stored_logo_url, bundle.logo_url, "the entry shows the group's icon, not the newcomer's"
    assert_equal "Aardvark.png", newcomer.reload.logo.blob.filename.to_s
  end

  test "a group of existing accounts without a stored icon takes it once from its then first account" do
    user = users(:empty)
    first = create_account("Alpha", balance: 1, institution: "Wise", owner: user, logo: "profile_image.png")
    create_account("Beta", balance: 1, institution: "Wise", owner: user, logo: "square-placeholder.png")
    create_account("Lone", balance: 1, institution: "Monzo", owner: user, logo: "square-placeholder.png")
    user.update!(default_account_order: "name_asc")
    assert_empty @family.institution_groups

    user_cash_group(user).institution_bundles
    user.update!(default_account_order: "name_desc")
    assert_no_difference -> { InstitutionGroup.count } do
      user_cash_group(user.reload).institution_bundles
    end

    group = @family.institution_groups.sole
    assert_equal [ "wise|", first.logo.blob ], [ group.key, group.logo.blob ]
  end

  test "a group whose first account shows Brandfetch takes that choice, and a missing icon shows the first account's fallback" do
    Setting.stubs(:brand_fetch_client_id).returns("client-id")
    first = create_account("Alpha", balance: 1, institution: "Wise", domain: "wise.com")
    first.update!(logo_selection: :brandfetch)
    create_account("Beta", balance: 1, institution: "Wise", domain: "wise.com", logo: "square-placeholder.png")

    bundle = cash_group.institution_bundles.sole

    assert @family.institution_groups.sole.logo_brandfetch?
    assert_equal first.brandfetch_logo_url, bundle.logo_url
  end

  test "an institution's slug names its bundle within one group" do
    create_account("Wise A", balance: 1, institution: "Wise")
    create_account("Wise B", balance: 1, institution: "Wise")
    create_account("Wise card", balance: 1, institution: "Wise", accountable: CreditCard.new)
    create_account("Wise card 2", balance: 1, institution: "Wise", accountable: CreditCard.new)

    balance_sheet = BalanceSheet.new(@family)
    cash, card = balance_sheet.account_groups.flat_map(&:institution_bundles)

    assert_not_equal cash.slug, card.slug
    assert_equal %w[Wise\ card Wise\ card\ 2], balance_sheet.institution_bundle(card.slug).accounts.map(&:name).sort
    assert_nil balance_sheet.institution_bundle("depository-000000000000")
  end
end
