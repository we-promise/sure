require "test_helper"

class Account::LogoFetcherTest < ActiveSupport::TestCase
  GOOGLE_URL = "https://www.google.com/s2/favicons?domain=tbank.ru&sz=256"
  DUCKDUCKGO_URL = "https://icons.duckduckgo.com/ip3/tbank.ru.ico"
  YANDEX_URL = "https://favicon.yandex.net/favicon/v2/tbank.ru?size=120"

  setup do
    @account = accounts(:depository)
    @account.update_columns(institution_domain: "tbank.ru")
    stub_request(:get, YANDEX_URL).to_return(status: 404)
    stub_request(:get, /itunes\.apple\.com/).to_return(status: 200, body: { results: [] }.to_json)
    stub_request(:get, /play\.google\.com/).to_return(status: 404)
    stub_request(:get, /backapi\.rustore\.ru/).to_return(status: 404)
  end

  test "lists the real icons of every service, largest first" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(64))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 200, body: ico(128))
    stub_request(:get, YANDEX_URL).to_return(status: 200, body: png(16))

    candidates = Account::LogoFetcher.new(@account).candidates

    assert_equal [ [ "duckduckgo", 128 ], [ "google", 64 ] ], candidates.map { |icon| [ icon.source, icon.size ] }
  end

  test "prefers an app icon of the institution over favicons" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(180))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 404)
    Account::LogoFetcher::AppStore.any_instance.stubs(:icons).returns([
      Account::LogoFetcher::Icon.new(key: "appstore:1", source: "appstore", name: "T-Bank", body: png(512), size: 512, content_type: "image/png", extension: "png")
    ])

    assert Account::LogoFetcher.new(@account).fetch(auto: true)

    @account.reload
    assert_equal "appstore", @account.logo_source
    assert_equal "appstore:1", @account.logo_key
    assert_equal "T-Bank", @account.logo.blob.metadata["logo_name"]
  end

  test "a picked icon yields to a newer choice made while it downloaded" do
    stub_request(:get, YANDEX_URL).to_return(status: 200, body: png(120))
    fetcher = Account::LogoFetcher.new(@account)
    fetcher.stubs(:icon_for).with do
      Account.find(@account.id).update!(prefer_brandfetch_logo: true)
      true
    end.returns(Account::LogoFetcher::Icon.new(key: "yandex", source: "yandex", name: nil, body: png(120), size: 120,
                                               content_type: "image/png", extension: "png"))

    assert_not fetcher.fetch(source: "yandex")
    assert_not @account.reload.logo.attached?
    assert @account.prefer_brandfetch_logo?
  end

  test "a picked icon replaces an automatic one attached while it downloaded" do
    fetcher = Account::LogoFetcher.new(@account)
    fetcher.stubs(:icon_for).with do
      Account.find(@account.id).logo.attach(io: file_fixture("square-placeholder.png").open, filename: "tbank.ru.png",
                                            metadata: { "logo_source" => "google", "logo_key" => "google", "logo_auto" => true })
      true
    end.returns(Account::LogoFetcher::Icon.new(key: "yandex", source: "yandex", name: nil, body: png(120), size: 120,
                                               content_type: "image/png", extension: "png"))

    assert fetcher.fetch(source: "yandex")
    assert_equal "yandex", @account.reload.logo_source
    assert_not @account.logo_auto?
  end

  test "a picked icon is applied even if an automatic job dropped the old icon meanwhile" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "sberbank.ru.png",
                         metadata: { "logo_source" => "google", "logo_key" => "google", "logo_auto" => true })
    fetcher = Account::LogoFetcher.new(@account)
    fetcher.stubs(:icon_for).with do
      Account.find(@account.id).logo.purge
      true
    end.returns(Account::LogoFetcher::Icon.new(key: "yandex", source: "yandex", name: nil, body: png(120), size: 120,
                                               content_type: "image/png", extension: "png"))

    assert fetcher.fetch(source: "yandex")
    assert_equal "yandex", @account.reload.logo_source
  end

  test "a picked icon yields to the removal of a chosen icon while it downloaded" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")
    fetcher = Account::LogoFetcher.new(@account)
    fetcher.stubs(:icon_for).with do
      Account.find(@account.id).choose_logo("remove")
      true
    end.returns(Account::LogoFetcher::Icon.new(key: "yandex", source: "yandex", name: nil, body: png(120), size: 120,
                                               content_type: "image/png", extension: "png"))

    assert_not fetcher.fetch(source: "yandex")
    assert_not @account.reload.logo.attached?
  end

  test "an automatic fetch yields to an icon chosen while it searched" do
    icon = Account::LogoFetcher::Icon.new(key: "google", source: "google", name: nil, body: png(180), size: 180, content_type: "image/png", extension: "png")
    fetcher = Account::LogoFetcher.new(@account)
    fetcher.stubs(:candidates).with do
      Account.find(@account.id).logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")
      true
    end.returns([ icon ])

    assert_not fetcher.fetch(auto: true)
    assert_equal "mine.png", @account.reload.logo.filename.to_s
  end

  test "attaching an icon touches the account so the cached sidebar updates" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(180))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 404)
    @account.update_columns(updated_at: 1.day.ago)

    assert Account::LogoFetcher.new(@account).fetch(auto: true)

    assert_operator @account.reload.updated_at, :>, 1.hour.ago
  end

  test "an automatic fetch skips apps matched only by a parent domain" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(180))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 404)
    Account::LogoFetcher::GooglePlay.any_instance.stubs(:icons).returns([
      Account::LogoFetcher::Icon.new(key: "googleplay:ru.yandex.maps", source: "googleplay", name: "Maps", body: png(512), size: 512,
                                     content_type: "image/png", extension: "png", auto: false)
    ])

    assert Account::LogoFetcher.new(@account).fetch(auto: true)

    assert_equal "google", @account.reload.logo_source
  end

  test "never asks RuStore when fetching automatically" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(180))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 404)
    Account::LogoFetcher::RuStore.any_instance.expects(:icons).never

    assert Account::LogoFetcher.new(@account).fetch(auto: true)

    assert_equal "google", @account.reload.logo_source
  end

  test "matches app developer websites to the institution domain" do
    assert Account::LogoFetcher.same_site?("https://www.krungsri.com/en", "krungsri.com")
    assert Account::LogoFetcher.same_site?("https://bankffin.kz/ru", "bankffin.kz")
    assert Account::LogoFetcher.same_site?("https://ozon.ru", "finance.ozon.ru")
    assert_not Account::LogoFetcher.own_site?("https://ozon.ru", "finance.ozon.ru"), "a parent may be shared"
    assert Account::LogoFetcher.own_site?("https://app.krungsri.com", "krungsri.com")
    assert_not Account::LogoFetcher.same_site?("https://notkrungsri.com", "krungsri.com")
    assert_not Account::LogoFetcher.same_site?(nil, "krungsri.com")
  end

  test "attaches the largest icon and remembers it was picked automatically" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(64))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 200, body: ico(128))

    assert Account::LogoFetcher.new(@account).fetch(auto: true)

    @account.reload
    assert_equal ico(128).bytesize, @account.logo.blob.byte_size
    assert_equal "tbank.ru.ico", @account.logo.filename.to_s
    assert_equal "duckduckgo", @account.logo_source
    assert @account.logo_auto?
  end

  test "attaches the chosen source and stops preferring Brandfetch" do
    @account.update_columns(prefer_brandfetch_logo: true)
    stub_request(:get, YANDEX_URL).to_return(status: 200, body: png(120))

    assert Account::LogoFetcher.new(@account).fetch(source: "yandex")

    @account.reload
    assert_equal "yandex", @account.logo_source
    assert_not @account.logo_auto?
    assert_not @account.prefer_brandfetch_logo?
    assert_not_requested :get, GOOGLE_URL
  end

  test "follows the favicon service redirect" do
    stub_request(:get, GOOGLE_URL)
      .to_return(status: 301, headers: { "Location" => "https://t3.gstatic.com/faviconV2?url=http://tbank.ru&size=256" })
    stub_request(:get, "https://t3.gstatic.com/faviconV2?url=http://tbank.ru&size=256").to_return(status: 200, body: png(128))

    assert Account::LogoFetcher.new(@account).fetch(source: "google")

    assert_equal png(128).bytesize, @account.reload.logo.blob.byte_size
    assert_equal "image/png", @account.logo.content_type
  end

  test "reads the size of JPEG icons" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: jpeg(128))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 200, body: png(32))

    assert Account::LogoFetcher.new(@account).fetch

    assert_equal "image/jpeg", @account.reload.logo.content_type
    assert_equal "tbank.ru.jpg", @account.logo.filename.to_s
  end

  test "skips an ICO whose directory or image data is cut short" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(64))
    [ "\x00\x00\x01\x00\x01\x00".b, "\x00\x00\x01\x00\x01\x00\x20".b, ico(128).byteslice(0, 40) ].each do |cut|
      stub_request(:get, DUCKDUCKGO_URL).to_return(status: 200, body: cut)

      assert_equal [ "google" ], Account::LogoFetcher.new(@account).candidates.map(&:key)
    end
  end

  test "drops an icon over the size limit while reading it" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(180) + "\x00" * Account::LOGO_MAX_SIZE)
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 404)
    stub_request(:get, YANDEX_URL).to_return(status: 200, body: png(120))

    assert_equal [ "yandex" ], Account::LogoFetcher.new(@account).candidates.map(&:key)
  end

  test "skips a PNG or JPEG cut short" do
    stub_request(:get, GOOGLE_URL).to_return(status: 200, body: png(180).byteslice(0, 24))
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 200, body: jpeg(128).delete_suffix("\xFF\xD9".b))
    stub_request(:get, YANDEX_URL).to_return(status: 200, body: png(120))

    assert_equal [ "yandex" ], Account::LogoFetcher.new(@account).candidates.map(&:key)
  end

  test "searches the GB App Store for .uk domains" do
    @account.update_columns(institution_domain: "barclays.co.uk")

    assert_equal "gb", Account::LogoFetcher.new(@account).send(:countries).first
  end

  test "keeps the current logo when nothing usable is found" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")
    stub_request(:get, GOOGLE_URL).to_timeout
    stub_request(:get, DUCKDUCKGO_URL).to_return(status: 200, body: "<html>blocked</html>")
    stub_request(:get, YANDEX_URL).to_return(status: 200, body: png(1))

    assert_not Account::LogoFetcher.new(@account).fetch

    assert_equal "mine.png", @account.reload.logo.filename.to_s
  end

  test "does nothing without a usable institution domain or with an unknown source" do
    @account.update_columns(institution_domain: nil)
    assert_empty Account::LogoFetcher.new(@account).candidates

    @account.update_columns(institution_domain: "bad domain.ru")
    assert_not Account::LogoFetcher.new(@account).fetch

    @account.update_columns(institution_domain: "tbank.ru")
    assert_not Account::LogoFetcher.new(@account).fetch(source: "bing")

    assert_not_requested :get, /google|duckduckgo|yandex|itunes/
  end

  private
    def png(size)
      "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR" + [ size, size ].pack("NN") + "\x08\x06\x00\x00\x00".b + "\x00" * 4 +
        [ 0 ].pack("N") + "IEND\xAEB`\x82".b
    end

    def jpeg(size)
      app0 = "\xFF\xE0".b + [ 16 ].pack("n") + "JFIF\x00".b + "\x00" * 9
      sof0 = "\xFF\xC0".b + [ 17, 8, size, size, 3 ].pack("nCnnC") + "\x00" * 9
      "\xFF\xD8".b + app0 + sof0 + "\xFF\xD9".b
    end

    def ico(size)
      image = png(size)
      dimension = size >= 256 ? 0 : size
      "\x00\x00\x01\x00".b + [ 1 ].pack("v") + [ dimension, dimension, 0, 0 ].pack("C4") + [ 1, 32, image.bytesize, 22 ].pack("vvVV") + image
    end
end
