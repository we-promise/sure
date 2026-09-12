require "test_helper"

class BreadcrumbableTest < ActiveSupport::TestCase
  test "system health breadcrumbs use the active locale" do
    controller = Admin::SystemHealthController.new
    controller.set_request!(ActionDispatch::TestRequest.create)

    { de: [ "Startseite", "Systemstatus" ], en: [ "Home", "System Health" ] }.each do |locale, labels|
      I18n.with_locale(locale) do
        assert_equal labels.last, I18n.t("breadcrumbs.system_health", fallback: false, raise: true)
        assert_equal [ [ labels.first, "/" ], [ labels.last, nil ] ], controller.send(:breadcrumbs)
      end
    end
  end
end
