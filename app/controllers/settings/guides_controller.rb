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
    @guide_content = markdown.render(File.read(Rails.root.join("docs/onboarding/guide.md")))
  end
end
