class Settings::GuidesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.guides"), nil ]
    ]
    markdown = Redcarpet::Markdown.new(Redcarpet::Render::HTML,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true
    )
    default_guide_path = Rails.root.join("docs/onboarding/guide.md")
    localized_guide_path = Rails.root.join("docs/onboarding/guide.#{I18n.locale}.md")
    guide_source = File.read(localized_guide_path.exist? ? localized_guide_path : default_guide_path)
    guide_source.gsub!(/src="assets\/([^"]+)"/) do
      %(src="#{helpers.asset_path(Regexp.last_match(1))}")
    end

    @guide_content = markdown.render(guide_source)
  end
end
