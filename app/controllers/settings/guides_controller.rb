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
    guide_source = File.read(Rails.root.join("docs/onboarding/guide.md"))
    guide_source.gsub!(/src="assets\/([^"]+)"/) do
      %(src="#{helpers.asset_path(Regexp.last_match(1))}")
    end

    @guide_content = markdown.render(guide_source)
  end
end
