require "test_helper"

class FooterLocalizationViewTest < ActionView::TestCase
  test "footer is translated in every supported locale with original brand attribution and links" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        html = Nokogiri::HTML.fragment(render(partial: "layouts/shared/footer"))
        attribution = I18n.t("layouts.shared.footer.community_fork", original_product: "Maybe Finance", fallback: false, raise: true)
        expected = "© #{Date.current.year}, #{Rails.configuration.x.brand_name} #{Rails.configuration.x.product_name} #{attribution}"
        assert_equal expected, html.at_css("p").text, "#{locale}: brand attribution"
        assert_includes html.at_css("p").text, "Maybe Finance"
        [ [ "privacy_policy", Rails.application.routes.url_helpers.privacy_path ], [ "terms_of_service", Rails.application.routes.url_helpers.terms_path ] ].each do |key, href|
          link = html.css("a").find { |node| node["href"] == href }
          assert link, "#{locale}: original #{key} link"
          assert_equal I18n.t("layouts.shared.footer.#{key}", fallback: false, raise: true), link.text
          assert_equal "_blank", link["target"]
          assert_nil link["rel"]
          assert_equal "text-secondary", link["class"]
        end
        assert_equal 2, html.css("a").size
      end
    end
  end
end
