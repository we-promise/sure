namespace :ai do
  desc "Regenerate the routing and manifest table in docs/llm-guides/ai-pipeline.md from Ai::Routes"
  task routes_doc: :environment do
    path = Rails.root.join("docs/llm-guides/ai-pipeline.md")
    start_marker, end_marker = "<!-- ai:routes_doc -->", "<!-- /ai:routes_doc -->"
    guide = File.read(path)
    abort "#{path} has no #{start_marker} … #{end_marker} block" unless guide.include?(start_marker) && guide.include?(end_marker)

    table = "#{start_marker}\n#{Ai::Routes.doc_table}\n#{end_marker}"
    File.write(path, guide.sub(/#{Regexp.escape(start_marker)}.*?#{Regexp.escape(end_marker)}/m) { table })
    puts "Updated #{path.relative_path_from(Rails.root)}"
  end
end
