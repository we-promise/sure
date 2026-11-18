require "test_helper"

class Account::LogoFetcher::RuStoreTest < ActiveSupport::TestCase
  SEARCH_URL = "https://backapi.rustore.ru/applicationData/apps"
  ICON = "https://static.rustore.ru/apk/2063500440/content/ICON/bank.png"

  setup do
    @store = Account::LogoFetcher::RuStore.new(domain: "bank.yandex.ru", term: "Яндекс Банк", client: Account::LogoFetcher::Client.new)
    stub_request(:get, ICON).to_return(status: 200, body: png(512))
  end

  test "returns icons of apps whose package name holds the domain's brand" do
    stub_search(
      app("com.yandex.bank", "Яндекс Пэй"),
      app("ru.ozon.fintech.finance", "Ozon Банк"),
      app("com.bank.online", "Some bank")
    )

    icons = @store.icons

    assert_equal [ "rustore:com.yandex.bank" ], icons.map(&:key)
    assert_equal [ 512, "rustore", "Яндекс Пэй" ], [ icons.first.size, icons.first.source, icons.first.name ]
  end

  test "returns apps named after the institution and other apps of their brand" do
    store = Account::LogoFetcher::RuStore.new(domain: "tbank.ru", term: "Т-Банк", client: Account::LogoFetcher::Client.new)
    stub_search(
      app("com.idamob.tinkoff.android", "Т-Банк: карты, вклады, кредиты"),
      app("ru.sberbankmobile", "СберБанк Онлайн"),
      app("ru.tinkoff.sme", "Т-Бизнес"),
      term: "Т-Банк"
    )

    assert_equal [ "rustore:com.idamob.tinkoff.android", "rustore:ru.tinkoff.sme" ], store.icons.map(&:key)
  end

  test "finds a picked app again by its package" do
    stub_search(app("ru.yandex.searchplugin", "Яндекс Старт", icon: "https://static.rustore.ru/other.png"), app("com.yandex.bank", "Яндекс Пэй"))

    assert_equal "rustore:com.yandex.bank", @store.icon("com.yandex.bank").key
    assert_nil @store.icon("ru.ozon.fintech.finance")
  end

  test "rejects icons outside RuStore's image host" do
    stub_search(app("com.yandex.bank", "Яндекс Пэй", icon: "https://evil.example/icon.png"))

    assert_empty @store.icons
  end

  private
    def stub_search(*apps, term: "Яндекс Банк")
      stub_request(:get, SEARCH_URL)
        .with(query: hash_including(query: term))
        .to_return(status: 200, body: { code: "OK", body: { content: apps } }.to_json)
    end

    def app(package, name, icon: ICON)
      { packageName: package, appName: name, iconUrl: icon }
    end

    def png(size)
      "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR" + [ size, size ].pack("NN") + "\x08\x06\x00\x00\x00".b + "\x00" * 4 +
        [ 0 ].pack("N") + "IEND\xAEB`\x82".b
    end
end
