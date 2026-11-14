require "test_helper"

# The prompt checks: every prompt folder renders its golden text byte for byte (golden files
# captured from the per-provider workers the prompts came from), every folder is complete and used, and
# no prompt text lives in locale YAML.
class AiPromptsTest < ActiveSupport::TestCase
  GOLDEN = Rails.root.join("test/fixtures/files/ai_prompts")

  TRANSACTIONS = [
    { id: "txn_1", amount: 12.5, classification: "expense", description: "STARBUCKS 1234 SEATTLE", merchant: nil },
    { id: "txn_2", amount: 2500, classification: "income", description: "ACME CORP PAYROLL", merchant: "Acme" }
  ].freeze
  CATEGORIES = [
    { id: "cat_1", name: "Coffee Shops", is_subcategory: true, parent_id: "cat_0" },
    { id: "cat_2", name: "Salary", is_subcategory: false, parent_id: nil }
  ].freeze
  USER_MERCHANTS = [ { id: "mer_1", name: "Acme" } ].freeze
  MERCHANTS = [ { id: "pm_1", name: "Starbucks" }, { id: "pm_2", name: "Acme Corp" } ].freeze
  CHARGES = [
    { date: "2026-09-01", amount: "15.99", name: "NETFLIX.COM" },
    { date: "2026-10-01", amount: "15.99", name: "NETFLIX.COM" }
  ].freeze
  CURRENT_CONFIG = { name: "Netflix", amount: "15.99", frequency: "monthly", day_of_month: 1 }.freeze

  # Where the prompts differ from the golden files: Anthropic's don't name a tool to return the
  # answer through, because both transports use with_schema. Everything else matches.
  TOOL_SENTENCE_REMOVED = {
    "categorize_transactions_anthropic" => [ "Your job is to auto-categorize each transaction\nand return the result via the report_categorizations tool.", "Your job is to auto-categorize each transaction." ],
    "detect_merchants_anthropic" => [ "for each transaction and return the result via the report_merchants tool.", "for each transaction." ],
    "enhance_merchants_anthropic" => [ "the business website URL for each and return the result via the report_enhancements tool.", "the business website URL for each." ],
    "bill_setup_anthropic" => [ "propose the bill's configuration via the\nreport_bill_setup tool.", "propose the bill's configuration." ]
  }.freeze

  FEATURES = {
    "categorize_transactions" => [ :categorize, { transactions: TRANSACTIONS, categories: CATEGORIES } ],
    "detect_merchants" => [ :detect_merchants, { transactions: TRANSACTIONS, merchants: USER_MERCHANTS } ],
    "enhance_merchants" => [ :enhance_merchants, { merchants: MERCHANTS } ]
  }.freeze

  def render(name, feature, **locals)
    route = Ai::Route.new(feature:, model: AiTestHelper.test_config.models.first, prompt: name)
    Ai::Prompt.for(feature, default: name, route:, family: nil, locale: nil, locals:)
  end

  def golden(variant, part, name: variant)
    text = GOLDEN.join("#{variant}.#{part}.txt").read
    old, new = TOOL_SENTENCE_REMOVED[name] if part == "instructions"
    old ? text.sub(old, new) : text
  end

  FEATURES.each do |base, (feature, locals)|
    [ base, "#{base}_simple", "#{base}_anthropic" ].each do |name|
      test "#{name} renders today's text" do
        rendered = render(name, feature, **locals)

        assert_equal golden(name, "instructions"), rendered.instructions
        assert_equal golden(name, "input"), rendered.input
      end
    end
  end

  %w[bill_setup bill_setup_anthropic].each do |name|
    test "#{name} renders today's text, filling and configuring" do
      fill = render(name, :bill_setup, charges: CHARGES, categories: %w[Entertainment Utilities], current_config: nil, configure_mode: false)
      configure = render(name, :bill_setup, charges: CHARGES, categories: %w[Entertainment Utilities], current_config: CURRENT_CONFIG,
                                            configure_mode: true)

      assert_equal golden(name, "instructions"), fill.instructions
      assert_equal golden(name, "input"), fill.input
      assert_equal golden("#{name}.configure", "instructions", name:), configure.instructions
      assert_equal golden("#{name}.configure", "input", name:), configure.input
    end
  end

  test "the removed tool sentences are the only difference from today's Anthropic text" do
    TOOL_SENTENCE_REMOVED.each do |name, (old, _new)|
      assert_includes GOLDEN.join("#{name}.instructions.txt").read, old, name
      assert_not_includes Ai::Prompt::ROOT.join(name, "instructions.txt.erb").read, "tool", name
    end
  end

  test "a family override replaces the instructions as plain text, never compiled" do
    family = families(:dylan_family)
    family.stubs(:ai_prompt).with(:categorize_transactions).returns("Sort these. <%= ENV.keys %>")

    rendered = Ai::Prompt.for(:categorize, default: "categorize_transactions", route: nil, family:, locale: nil,
                                           locals: { transactions: TRANSACTIONS, categories: CATEGORIES })

    assert_equal "Sort these. <%= ENV.keys %>", rendered.instructions
    assert_equal golden("categorize_transactions", "input"), rendered.input
    assert rendered.override
  end

  test "every prompt folder has both parts, and every locale file a base" do
    folders = Ai::Prompt::ROOT.children.select(&:directory?).reject { _1.basename.to_s == "shared" }

    folders.each do |folder|
      assert folder.join("instructions.txt.erb").exist?, "#{folder.basename} has no instructions.txt.erb"
      assert folder.join("input.txt.erb").exist?, "#{folder.basename} has no input.txt.erb"
      folder.glob("*.*.txt.erb").each do |localized|
        part, locale = localized.basename.to_s.split(".").first(2)
        assert folder.join("#{part}.txt.erb").exist?, "#{localized} has no base file"
        assert_includes I18n.available_locales.map(&:to_s), locale, "#{localized} names an unknown locale"
      end
    end
  end

  test "every prompt folder is one a route can name" do
    used = Ai::LegacyEnvConfig::PROMPTS.flat_map do |feature, base|
      [ base, "#{base}_anthropic", *("#{base}_simple" if Ai::LegacyEnvConfig::SIMPLE_PROMPTS.include?(feature)) ]
    end
    used += Ai::Config::Model::OCR_PROMPTS.map { "ocr_#{_1}" }
    # extract_pdf's two generations each run their own folder; a route entry's prompt doesn't name them.
    used += [ Ai::Generations::ReadPdf, Ai::Generations::ExtractBankStatement ].map(&:prompt_key)
    folders = Ai::Prompt::ROOT.children.select(&:directory?).map { _1.basename.to_s } - %w[shared]

    assert_empty folders - used, "prompt folders no route can name"
    assert_empty used - folders, "prompts a route names with no folder"
  end

  test "no prompt text lives in locale YAML" do
    first_lines = Ai::Prompt::ROOT.glob("*/instructions.txt.erb").map { _1.read.lines.first.strip }
    Rails.root.glob("config/locales/**/*.yml").each do |file|
      text = file.read
      first_lines.each { |line| assert_not_includes text, line, "#{file} holds prompt text" }
    end
  end
end
