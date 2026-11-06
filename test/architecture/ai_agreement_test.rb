require "test_helper"

# PR #4440's E2, kept: in every setup today's code supports, each place that shows or starts an AI
# feature gives the same answer as Ai.available? (ai-plumbing-redesign.md, section 17).
#
# Chat's entry points are asked too, but they move onto the router only in PR 6, so their known
# disagreements are on CHAT_ALLOWLIST. The list may only shrink: an entry that no longer
# disagrees fails the test, and PR 6 empties it.
class AiAgreementTest < ActionDispatch::IntegrationTest
  include AiLegacySetups
  include BillsHelper
  include InsightsHelper

  # [setup, entry point] => why chat's entry point and the router disagree until PR 6.
  CHAT_ALLOWLIST = {
    %w[C6 chat_page] => "the chat page is offered, but no model is set, so every turn fails",
    %w[C8 chat_page] => "the chat page is offered, but chat's allow-list refuses o4-mini, so every turn fails",
    %w[C8 dig_in] => "Dig in asks for the batch provider, which takes o4-mini; chat refuses it",
    %w[C8 bills_chat] => "the bills chat buttons ask for the batch provider, which takes o4-mini; chat refuses it",
    %w[M5 chat_page] => "mcp_only turns chat off through User#ai_available?; Ai::Consent gets that line in PR 6",
    %w[M5 bills_chat] => "mcp_only turns the bills chat buttons off; Ai::Consent gets that line in PR 6",
    %w[M5 dig_in] => "mcp_only turns Dig in off; Ai::Consent gets that line in PR 6"
  }.freeze

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.update!(assistant_type: "builtin")
    merchant = ProviderMerchant.create!(name: "Agreement Test Shop", source: "plaid")
    transactions(:one).update_columns(merchant_id: merchant.id)
  end

  test "every entry point agrees with the router in every setup" do
    report = {}
    chat_disagreements = []

    SETUPS.each_key do |id|
      with_self_hosting do
        in_ai_setup(id, family: @family) do
          Current.session = @user.sessions.order(:created_at).last
          answers(id).each do |entry, (feature, shown)|
            routed = Ai.available?(feature, family: @family, user: @user)
            report[[ id, entry ]] = [ shown, routed ]
            next if shown == routed

            if feature == :chat
              chat_disagreements << [ id, entry.to_s ]
            else
              flunk "#{id} (#{SETUPS[id].first}): #{entry} says #{shown ? "available" : "unavailable"}, the router says #{routed}"
            end
          end
        end
      end
    end

    assert_equal CHAT_ALLOWLIST.keys.sort, chat_disagreements.sort,
                 "chat's disagreements changed; update CHAT_ALLOWLIST (it may only shrink)\n#{format_report(report)}"
  end

  private
    # entry point => [feature, whether it's shown or offered]
    def answers(id)
      get family_merchants_path
      assert_response :success, id
      enhance_shown = response.body.include?(enhance_family_merchants_path)

      get new_import_path
      document_upload_shown = css_select("form[data-turbo-frame=_top] input[type=file][onchange='this.form.requestSubmit()']").size > 1

      offered = Rule::Registry::TransactionResource.new(Rule.new(family: @family, resource_type: "transaction")).action_executors.map(&:key)
      tools = Assistant.function_classes(@user)
      diagnostic = Assistant::Function::GetUncategorizedTransactions.new(@user).send(:enrichment_diagnostic)

      {
        enhance_button: [ :enhance_merchants, enhance_shown ],
        categorize_rule_action: [ :categorize, offered.include?("auto_categorize") ],
        detect_merchants_rule_action: [ :detect_merchants, offered.include?("auto_detect_merchants") ],
        document_upload: [ :embed, document_upload_shown ],
        mcp_import_bank_statement: [ :extract_pdf, tools.include?(Assistant::Function::ImportBankStatement) ],
        uncategorized_diagnostic: [ :detect_merchants, diagnostic[:llm_provider_configured] ],
        chat_page: [ :chat, @user.reload.ai_enabled? ],
        dig_in: [ :chat, insight_dig_in_available?(Insight.new(family: @family)) ],
        bills_chat: [ :chat, bills_ai_chat_available? ]
      }
    end

    def format_report(report)
      report.map { |(id, entry), (shown, routed)| "#{id} #{entry}: shown=#{shown} router=#{routed}" }.join("\n")
    end
end
