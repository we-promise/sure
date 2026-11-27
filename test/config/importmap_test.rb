require "test_helper"

class ImportmapTest < ActiveSupport::TestCase
  # `pin_all_from` only picks up .js files, so every .mjs helper needs its own
  # pin. One left out fails silently: the browser cannot resolve the bare
  # specifier and every controller importing it stops loading.
  test "every .mjs helper under utils is pinned" do
    imports = JSON.parse(Rails.application.importmap.to_json(resolver: ActionController::Base.helpers)).fetch("imports")

    Rails.root.glob("app/javascript/utils/*.mjs").each do |path|
      specifier = "utils/#{path.basename(".mjs")}"
      assert imports.key?(specifier), "#{path.relative_path_from(Rails.root)} is not pinned; add `pin \"#{specifier}\", to: \"#{specifier}.mjs\"` to config/importmap.rb"
    end
  end
end
