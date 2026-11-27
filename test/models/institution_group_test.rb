require "test_helper"

class InstitutionGroupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:empty)
  end

  test "blank fields are saved as nothing set, and the domain is normalized" do
    settings = @family.institution_groups.create!(key: "wise", name: "  ", currency: " ", institution_domain: "https://www.wise.com/gb")

    assert_nil settings.name
    assert_nil settings.currency
    assert_equal "wise.com", settings.institution_domain
  end

  test "the currency must be a supported one" do
    assert_not @family.institution_groups.new(key: "wise", currency: "XYZ").valid?
    assert @family.institution_groups.new(key: "wise", currency: "eur").valid?
  end

  test "an institution has one row of settings per family" do
    @family.institution_groups.create!(key: "wise")

    assert_not @family.institution_groups.new(key: "wise").valid?
    assert families(:dylan_family).institution_groups.new(key: "wise").valid?
  end

  test "an account's institution key is its institution's name and domain, ignoring case and spacing" do
    assert_equal "wise business|wise.com", InstitutionGroup.key_for(Account.new(institution_name: "  Wise   BUSINESS ", institution_domain: "https://www.Wise.com/"))
    assert_equal "wise business|", InstitutionGroup.key_for(Account.new(institution_name: "Wise Business"))
    assert_equal "|wise.com", InstitutionGroup.key_for(Account.new(institution_domain: "wise.com"))
    assert_nil InstitutionGroup.key_for(Account.new)
  end

  test "saving to accounts writes the name and domain onto them and moves the settings to the new name's key" do
    accounts = wise_accounts
    settings = @family.institution_groups.create!(key: "wise", currency: "EUR")
    settings.assign_attributes(name: "Wise Business", institution_domain: "wise.com", inherited_name: "Wise")

    assert_equal settings, settings.save_to_accounts(accounts)

    assert_equal [ "wise business|wise.com", nil, nil, "EUR" ], settings.reload.slice(:key, :name, :institution_domain, :currency).values
    assert_equal [ [ "Wise Business", "wise.com" ] ] * 2, accounts.map { |account| account.reload.slice(:institution_name, :institution_domain).values }
  end

  test "with no account to write to, the name and domain stay on the settings" do
    wise_accounts
    settings = @family.institution_groups.new(key: "wise", name: "My Wise", institution_domain: "wise.com", inherited_name: "Wise")

    assert settings.save_to_accounts([])

    assert_equal [ "wise", "My Wise", "wise.com" ], settings.reload.slice(:key, :name, :institution_domain).values
  end

  test "a domain saved on the settings, with no account to take it, gives the group's icon" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    lead = wise_accounts.first
    settings = @family.institution_groups.new(key: "wise", institution_domain: "wise.com", inherited_name: "Wise")
    assert settings.save_to_accounts([])

    assert_equal "wise.com", settings.logo_preview(lead).institution_domain
    assert_includes settings.brandfetch_logo_url, "cdn.brandfetch.io/wise.com/"
    assert_includes settings.logo_preview(lead).brandfetch_logo_url, "cdn.brandfetch.io/wise.com/"
  end

  test "a name the accounts take from their domain is not written into their names" do
    accounts = wise_accounts(institution_name: nil, institution_domain: "wise.com")
    settings = @family.institution_groups.new(key: "|wise.com", name: "wise.com", institution_domain: "wise.com",
                                              inherited_name: "wise.com", inherited_domain: "wise.com")

    assert settings.save_to_accounts(accounts)

    assert_equal [ nil, nil ], accounts.map { |account| account.reload.read_attribute(:institution_name) }
    assert_equal "|wise.com", settings.reload.key
  end

  test "moving into a key that has settings merges into them, what was saved winning over the default" do
    accounts = wise_accounts
    existing = @family.institution_groups.create!(key: "wise business|", name: "Override", institution_domain: "old.com", currency: "CHF")
    settings = @family.institution_groups.create!(key: "wise", currency: "EUR")
    settings.assign_attributes(name: "Wise Business", currency: "", inherited_name: "Wise")

    assert_equal existing, settings.save_to_accounts(accounts)

    assert_not InstitutionGroup.exists?(settings.id)
    assert_equal [ nil, nil, "CHF" ], existing.reload.slice(:name, :institution_domain, :currency).values

    accounts.each { |account| account.update!(institution_name: "Wise") }
    settings = @family.institution_groups.new(key: "wise", name: "Wise Business", currency: "SGD", inherited_name: "Wise")
    assert_equal existing, settings.save_to_accounts(accounts)
    assert_equal "SGD", existing.reload.currency
  end

  test "a picked icon is downloaded once, for the domain saved, and the one image given to every account" do
    accounts = wise_accounts
    icon = Account::LogoFetcher::Icon.new(key: "appstore:1", source: "appstore", name: "Wise", body: file_fixture("square-placeholder.png").binread,
                                          size: 512, content_type: "image/png", extension: "png")
    Account::LogoFetcher.any_instance.expects(:icon).once.with("appstore:1").returns(icon)
    settings = @family.institution_groups.new(key: "wise", name: "Wise", institution_domain: "wise.com", inherited_name: "Wise",
                                              logo_choice: Account::LogoChoice.new(choice: "appstore:1"))

    assert_no_enqueued_jobs only: AccountLogoFetchJob do
      assert settings.save_to_accounts(accounts)
    end

    blobs = accounts.map { |account| account.reload.logo.blob }
    assert_equal 1, blobs.uniq.size
    assert_equal blobs.first, settings.reload.logo.blob, "the group takes the icon too"
    assert_equal [ "appstore:1", "wise.com" ], blobs.first.metadata.values_at("logo_key", "logo_domain")
    assert_not settings.logo_choice.not_applied?
  end

  test "an icon that cannot be downloaded leaves the icons alone and the new domain's usual fetch" do
    accounts = wise_accounts
    Account::LogoFetcher.any_instance.expects(:icon).returns(nil)
    settings = @family.institution_groups.new(key: "wise", name: "Wise", institution_domain: "wise.com", inherited_name: "Wise",
                                              logo_choice: Account::LogoChoice.new(choice: "appstore:1"))

    assert_enqueued_jobs 2, only: AccountLogoFetchJob do
      assert settings.save_to_accounts(accounts)
    end

    assert settings.logo_choice.not_applied?
    assert_equal [ "wise.com" ] * 2, accounts.map { |account| account.reload.institution_domain }
    assert accounts.none? { |account| account.logo.attached? }
  end

  test "an account that fails to save rolls back the accounts written before it and the settings" do
    accounts = wise_accounts
    accounts.second.name = ""
    settings = @family.institution_groups.new(key: "wise", name: "Wise Business", currency: "EUR", inherited_name: "Wise")

    assert_nil settings.save_to_accounts(accounts)

    assert_equal "Wise", accounts.first.reload.institution_name
    assert_not settings.persisted?
    assert_equal [ "wise", "Wise Business" ], [ settings.key, settings.name ], "the form shows what was submitted"
    assert settings.errors[:base].any?
  end

  private
    def wise_accounts(institution_name: "Wise", institution_domain: nil)
      %w[EUR GBP].map do |currency|
        @family.accounts.create!(name: "Wise #{currency}", balance: 1, currency: "USD", institution_name: institution_name,
                                 institution_domain: institution_domain, accountable: Depository.new)
      end
    end
end
