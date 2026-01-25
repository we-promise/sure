module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides
    def set_breadcrumbs
      @breadcrumbs = [
        [ I18n.t("breadcrumbs.home", default: "Home"), root_path ],
        [ I18n.t("breadcrumbs.#{controller_name}", default: controller_name.titleize), nil ]
      ]
    end
end
