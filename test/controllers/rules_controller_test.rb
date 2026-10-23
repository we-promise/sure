require "test_helper"

class RulesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get new" do
    get new_rule_url(resource_type: "transaction")
    assert_response :success
  end

  test "should get new with pre-filled name and action" do
    category = categories(:food_and_drink)
    get new_rule_url(
      resource_type: "transaction",
      name: "Starbucks",
      action_type: "set_transaction_category",
      action_value: category.id
    )
    assert_response :success

    assert_select "input[name='rule[name]'][value='Starbucks']"
    assert_select "input[name*='[value]'][value='Starbucks']"
    assert_select "select[name*='[condition_type]'] option[selected][value='transaction_name']"
    assert_select "select[name*='[action_type]'] option[selected][value='set_transaction_category']"
    assert_select "select[name*='[value]'] option[selected][value='#{category.id}']"
  end

  test "should get edit" do
    get edit_rule_url(rules(:one))
    assert_response :success
  end

  # "Set all transactions with a name like 'starbucks' and an amount between 20 and 40 to the 'food and drink' category"
  test "creates rule with nested conditions" do
    post rules_url, params: {
      rule: {
        effective_date: 30.days.ago.to_date,
        resource_type: "transaction",
        conditions_attributes: {
          "0" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "starbucks"
          },
          "1" => {
            condition_type: "compound",
            operator: "and",
            sub_conditions_attributes: {
              "0" => {
                condition_type: "transaction_amount",
                operator: ">",
                value: 20
              },
              "1" => {
                condition_type: "transaction_amount",
                operator: "<",
                value: 40
              }
            }
          }
        },
        actions_attributes: {
          "0" => {
            action_type: "set_transaction_category",
            value: categories(:food_and_drink).id
          }
        }
      }
    }

    rule = @user.family.rules.order("created_at DESC").first

    # Rule
    assert_equal "transaction", rule.resource_type
    assert_not rule.active # Not active by default
    assert_equal 30.days.ago.to_date, rule.effective_date

    # Conditions assertions
    assert_equal 2, rule.conditions.count
    compound_condition = rule.conditions.find { |condition| condition.condition_type == "compound" }
    assert_equal "compound", compound_condition.condition_type
    assert_equal 2, compound_condition.sub_conditions.count

    # Actions assertions
    assert_equal 1, rule.actions.count
    assert_equal "set_transaction_category", rule.actions.first.action_type
    assert_equal categories(:food_and_drink).id, rule.actions.first.value

    assert_redirected_to confirm_rule_url(rule, reload_on_close: true)
  end

  test "creating an email rule through the form records its current matches as the baseline" do
    account = @user.family.accounts.create!(name: "Baseline", balance: 1000, currency: "USD", accountable: Depository.new)
    match = account.entries.create!(
      name: "Baseline cafe", date: Date.current, amount: 10, currency: "USD", entryable: Transaction.new
    ).transaction

    post rules_url, params: {
      rule: {
        name: "Baseline cafe alerts",
        resource_type: "transaction",
        conditions_attributes: { "0" => { condition_type: "transaction_name", operator: "like", value: "baseline cafe" } },
        actions_attributes: { "0" => { action_type: "send_email_notification" } }
      }
    }

    rule = @user.family.rules.find_by!(name: "Baseline cafe alerts")
    assert_redirected_to confirm_rule_url(rule, reload_on_close: true)
    assert_equal [ match.id ], NotificationDelivery.where(rule: rule).pluck(:transaction_id)
  end

  test "creates rule with a split_transaction action from split_rows params" do
    category = categories(:food_and_drink)

    post rules_url, params: {
      rule: {
        effective_date: 30.days.ago.to_date,
        resource_type: "transaction",
        conditions_attributes: {
          "0" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "Netflix+Hulu Bundle"
          }
        },
        actions_attributes: {
          "0" => {
            action_type: "split_transaction",
            split_rows: {
              "0" => { type: "percentage", name: "Netflix", share: "70", category_id: category.id },
              "1" => { type: "percentage", name: "Hulu", share: "30", category_id: "" }
            }
          }
        }
      }
    }

    rule = @user.family.rules.order("created_at DESC").first

    assert_equal 1, rule.actions.count
    action = rule.actions.first
    assert_equal "split_transaction", action.action_type

    parsed_value = JSON.parse(action.value)
    assert_equal [ "Netflix", "Hulu" ], parsed_value["splits"].map { |s| s["name"] }
    assert_equal [ "percentage", "percentage" ], parsed_value["splits"].map { |s| s["type"] }
    assert_equal category.id, parsed_value["splits"].first["category_id"]
    assert_nil parsed_value["splits"].last["category_id"]

    assert_redirected_to confirm_rule_url(rule, reload_on_close: true)
  end

  test "updates the split rows of an existing split_transaction action" do
    rule = @user.family.rules.create!(
      name: "Existing split",
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "rent") ],
      actions: [
        Rule::Action.new(
          action_type: "split_transaction",
          value: { splits: [ { type: "percentage", name: "A", share: "50" }, { type: "percentage", name: "B", share: "50" } ] }.to_json
        )
      ]
    )
    action = rule.actions.sole

    patch rule_url(rule), params: {
      rule: {
        actions_attributes: {
          "0" => {
            id: action.id,
            action_type: "split_transaction",
            split_rows: {
              "0" => { type: "percentage", name: "A", share: "60", category_id: categories(:food_and_drink).id },
              "1" => { type: "percentage", name: "B", share: "40", category_id: "" }
            }
          }
        }
      }
    }

    splits = JSON.parse(action.reload.value)["splits"]
    assert_equal [ "60", "40" ], splits.map { |split| split["share"] }
    assert_equal categories(:food_and_drink).id, splits.first["category_id"]
  end

  test "rejects unknown action and resource types on create without saving or failing to render" do
    {
      "one unknown action" => { resource_type: "transaction", actions_attributes: { "0" => { action_type: "garbage" } } },
      "two unknown actions" => { resource_type: "transaction",
                                 actions_attributes: { "0" => { action_type: "garbage" }, "1" => { action_type: "garbage" } } },
      "unknown resource type" => { resource_type: "account", actions_attributes: { "0" => { action_type: "exclude_transaction" } } },
      "unknown resource type, no action" => { resource_type: "account" }
    }.each do |label, rule_params|
      assert_no_difference [ "Rule.count", "Rule::Action.count" ], label do
        post rules_url, params: { rule: rule_params }
      end

      assert_response :unprocessable_entity, label
      assert_equal "text/plain", response.media_type, label
      assert_match(/type is not included in the list/i, response.body, label)
    end
  end

  test "rejects an unknown action type on update" do
    rule = rules(:one)
    action = rule.actions.first
    original_type = action.action_type

    patch rule_url(rule), params: { rule: { actions_attributes: { "0" => { id: action.id, action_type: "garbage" } } } }

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_equal original_type, action.reload.action_type
  end

  test "rejects an unknown resource type on update" do
    rule = rules(:one)

    patch rule_url(rule), params: { rule: { resource_type: "account" } }

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_equal "transaction", rule.reload.resource_type
  end

  test "does not render an unknown action type that is marked for destruction" do
    rule = rules(:one)
    action = rule.actions.first
    original_type = action.action_type

    patch rule_url(rule), params: {
      rule: { actions_attributes: { "0" => { id: action.id, action_type: "garbage", _destroy: "1" } } }
    }

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_equal original_type, action.reload.action_type
  end

  test "new ignores an unknown resource type or action type" do
    get new_rule_url(resource_type: "account")
    assert_response :success
    assert_select "input[name='rule[resource_type]'][value='transaction']"

    get new_rule_url(resource_type: "transaction", action_type: "garbage", action_value: "x")
    assert_response :success
    assert_select "ul[data-rules-target='actionsList'] li", 0
  end

  test "can update rule" do
    rule = rules(:one)

    assert_difference -> { Rule.count } => 0,
      -> { Rule::Condition.count } => 1,
      -> { Rule::Action.count } => 1 do
      patch rule_url(rule), params: {
        rule: {
          active: false,
          conditions_attributes: {
            "0" => {
              id: rule.conditions.first.id,
              value: "new_value"
            },
            "1" => {
              condition_type: "transaction_amount",
              operator: ">",
              value: 100
            }
          },
          actions_attributes: {
            "0" => {
              id: rule.actions.first.id,
              value: "new_value"
            },
            "1" => {
              action_type: "set_transaction_tags",
              value: tags(:one).id
            }
          }
        }
      }
    end

    rule.reload

    assert_not rule.active
    assert_equal "new_value", rule.conditions.order("created_at ASC").first.value
    assert_equal "new_value", rule.actions.order("created_at ASC").first.value
    assert_equal tags(:one).id, rule.actions.order("created_at ASC").last.value
    assert_equal "100", rule.conditions.order("created_at ASC").last.value

    assert_redirected_to rules_url
  end

  test "saves stop processing" do
    rule = rules(:one)

    patch rule_url(rule), params: { rule: { stop_processing: "1" } }

    assert rule.reload.stop_processing
  end

  test "index lists rules in run order" do
    family = @user.family
    newest = family.rules.create!(resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    ordered_ids = [ newest.id ] + (family.rules.ordered.pluck(:id) - [ newest.id ])
    Rule.update_positions!(family, ordered_ids)

    get rules_url

    assert_response :success
    assert_equal ordered_ids, css_select("[data-sortable-list-target='item']").map { |item| item["data-sortable-list-id"] }
  end

  test "reorder saves the new order" do
    family = @user.family
    second = family.rules.create!(resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    ordered_ids = family.rules.ordered.pluck(:id).reverse

    patch reorder_rules_url, params: { rule_ids: ordered_ids }, as: :json

    assert_response :no_content
    assert_equal ordered_ids, family.rules.ordered.pluck(:id)
    assert_equal second.id, ordered_ids.first
  end

  test "reorder rejects rules of another family" do
    family = @user.family
    other_rule = families(:empty).rules.create!(resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    before = family.rules.ordered.pluck(:id, :position)

    patch reorder_rules_url, params: { rule_ids: family.rules.pluck(:id) + [ other_rule.id ] }, as: :json

    assert_response :unprocessable_entity
    assert_equal before, family.rules.ordered.pluck(:id, :position)
    assert_equal 1, other_rule.reload.position
  end

  test "can destroy conditions and actions while editing" do
    rule = rules(:one)

    assert_equal 1, rule.conditions.count
    assert_equal 1, rule.actions.count

    patch rule_url(rule), params: {
      rule: {
        conditions_attributes: {
          "0" => { id: rule.conditions.first.id, _destroy: true },
          "1" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "new_condition"
          }
        },
        actions_attributes: {
          "0" => { id: rule.actions.first.id, _destroy: true },
          "1" => {
            action_type: "set_transaction_tags",
            value: tags(:one).id
          }
        }
      }
    }

    assert_redirected_to rules_url

    rule.reload

    assert_equal 1, rule.conditions.count
    assert_equal 1, rule.actions.count
  end

  test "can destroy rule" do
    rule = rules(:one)

    assert_difference [ "Rule.count", "Rule::Condition.count", "Rule::Action.count" ], -1 do
      delete rule_url(rule)
    end

    assert_redirected_to rules_url
  end

  test "index renders when rule has empty compound condition" do
    malformed_rule = @user.family.rules.build(resource_type: "transaction")
    malformed_rule.conditions.build(condition_type: "compound", operator: "and")
    malformed_rule.actions.build(action_type: "exclude_transaction")
    malformed_rule.save!

    get rules_url

    assert_response :success
    assert_includes response.body, I18n.t("rules.no_condition")
  end

  test "index uses next valid condition when first compound condition is empty" do
    rule = @user.family.rules.build(resource_type: "transaction")
    rule.conditions.build(condition_type: "compound", operator: "and")
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "edge-case-name")
    rule.actions.build(action_type: "exclude_transaction")
    rule.save!

    get rules_url

    assert_response :success

    assert_select "##{ActionView::RecordIdentifier.dom_id(rule)}" do
      assert_select "span", text: /edge-case-name/
      assert_select "span", text: /#{Regexp.escape(I18n.t("rules.no_condition"))}/, count: 0
      assert_select "p", text: /and 1 more condition/, count: 0
    end
  end

  test "index shows blocked count in recent runs summary" do
    rule = rules(:one)
    RuleRun.create!(
      rule: rule,
      execution_type: "manual",
      status: "success",
      transactions_queued: 10,
      transactions_processed: 7,
      transactions_modified: 4,
      pending_jobs_count: 0,
      executed_at: Time.current
    )

    get rules_url

    assert_response :success
    assert_select "th", text: /Queued\s+Processed\s+Modified\s+Blocked/
    assert_select "td", text: "10 / 7 / 4 / 3"
  end

  # The confirmation screen used to hardcode :openai, so it quoted a provider
  # that would not run — an Anthropic install saw the OpenAI model, and a family
  # on Jev saw whichever LLM model happened to be configured.
  test "confirm names the provider that will actually categorize" do
    rule = rules(:one)
    rule.actions.create!(action_type: "auto_categorize")
    @user.family.update!(categorization_provider: "jev")
    # The general stub catches the :openai lookup preferred_llm_provider makes;
    # the specific one wins for :jev.
    Provider::Registry.stubs(:get_provider).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:jev).returns(Provider::Jev.allocate)
    Provider::Jev.stubs(:effective_model).returns("~typesafe/jev-latest")

    get confirm_rule_url(rule)

    assert_response :success
    assert_match "~typesafe/jev-latest", response.body
  end

  test "confirm says the active rules above run first" do
    family = @user.family
    family.rules.destroy_all
    build = ->(name, active) do
      family.rules.create!(name: name, resource_type: "transaction", active: active,
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
    build.call("Active above", true)
    build.call("Inactive above", false)
    rule = build.call("Applied", true)
    build.call("Below", true)

    get confirm_rule_url(rule)
    assert_response :success
    assert_match I18n.t("rules.confirm.rules_above_notice", count: 1), response.body

    get confirm_rule_url(family.rules.find_by!(name: "Active above"))
    assert_response :success
    assert_no_match "run first", response.body
  end

  test "confirm does not name Jev when the family has not selected it" do
    rule = rules(:one)
    rule.actions.create!(action_type: "auto_categorize")
    assert_equal "llm", @user.family.categorization_provider

    get confirm_rule_url(rule)

    assert_response :success
    assert_no_match "~typesafe/jev-latest", response.body
  end

  test "should get confirm_all" do
    get confirm_all_rules_url
    assert_response :success
  end

  test "apply_all enqueues job and redirects" do
    assert_enqueued_with(job: ApplyAllRulesJob) do
      post apply_all_rules_url
    end

    assert_redirected_to rules_url
  end

  test "guest cannot create rule" do
    sign_in family_guest

    assert_no_difference "Rule.count" do
      post rules_url, params: { rule: { name: "Guest Rule", resource_type: "transaction" } }
    end

    assert_redirected_to accounts_url
  end

  test "guest cannot apply rule" do
    sign_in family_guest
    rule = rules(:one)

    assert_no_enqueued_jobs do
      post apply_rule_url(rule)
    end

    assert_redirected_to accounts_url
    assert_not rule.reload.active?
  end

  test "switching on an email rule records its baseline before queuing the run" do
    rule = email_rule_for(@user.family)

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      assert_enqueued_with(job: RuleJob) { post apply_rule_url(rule) }
    end

    assert rule.reload.active?
  end

  test "apply leaves an email rule off and queues nothing when its baseline times out" do
    rule = email_rule_for(@user.family)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_no_enqueued_jobs(only: RuleJob) { post apply_rule_url(rule) }

    assert_redirected_to rules_url
    assert_equal I18n.t("rules.notification_baseline_timed_out"), flash[:alert]
    assert_nil flash[:notice]
    assert_not rule.reload.active?
  end

  test "the active toggle leaves an email rule off and says why when its baseline times out" do
    rule = email_rule_for(@user.family)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    patch rule_url(rule), params: { rule: { active: "1" } }, as: :turbo_stream

    assert_response :success
    assert_equal I18n.t("rules.notification_baseline_timed_out"), flash[:alert]
    assert_nil flash[:notice]
    assert_not rule.reload.active?
  end

  # Rule::Action takes an email action's baseline in its commit callback, after
  # the update has saved. When that query times out the rule is switched off,
  # and the update must say so rather than report success.
  test "changing an action to an email action says the rule was switched off when its baseline times out" do
    rule = active_rule_without_email_for(@user.family)
    action = rule.actions.first
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    patch rule_url(rule), params: { rule: { actions_attributes: { "0" => { id: action.id, action_type: "send_email_notification" } } } }

    assert_equal I18n.t("rules.notification_baseline_timed_out"), flash[:alert]
    assert_nil flash[:notice]
    assert_equal "send_email_notification", action.reload.action_type
    assert_not rule.reload.active?
  end

  test "changing an action to an email action keeps the rule on and reports success when its baseline is recorded" do
    rule = active_rule_without_email_for(@user.family)
    action = rule.actions.first

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      patch rule_url(rule), params: { rule: { actions_attributes: { "0" => { id: action.id, action_type: "send_email_notification" } } } }
    end

    assert_equal I18n.t("rules.update.success"), flash[:notice]
    assert_nil flash[:alert]
    assert rule.reload.active?
  end

  test "the active toggle switches an email rule on when its baseline is recorded" do
    rule = email_rule_for(@user.family)

    assert_difference -> { NotificationDelivery.where(rule: rule).count }, 1 do
      patch rule_url(rule), params: { rule: { active: "1" } }, as: :turbo_stream
    end

    assert_equal I18n.t("rules.update.success"), flash[:notice]
    assert_nil flash[:alert]
    assert rule.reload.active?
  end

  test "member can create rule" do
    sign_in users(:family_member)

    assert_difference "Rule.count", 1 do
      post rules_url, params: {
        rule: {
          name: "Member Rule",
          resource_type: "transaction",
          actions_attributes: {
            "0" => {
              action_type: "set_transaction_category",
              value: categories(:food_and_drink).id } } } }
    end

    assert_redirected_to confirm_rule_path(Rule.order(:created_at).last, reload_on_close: true)
  end

  test "clear_ai_cache enqueues job and records the request in the debug log" do
    assert_enqueued_with(job: ClearAiCacheJob, args: [ @user.family ]) do
      post clear_ai_cache_rules_url
    end

    assert_redirected_to rules_url

    entry = DebugLogEntry.where(category: ClearAiCacheJob::DEBUG_CATEGORY, level: "info").sole
    assert_equal "AI cache reset requested from the rules page", entry.message
    assert_equal @user, entry.user
    assert_equal @user.family, entry.family
  end

  test "clear_ai_cache records an error when the job cannot be enqueued" do
    ClearAiCacheJob.expects(:perform_later).with(@user.family).raises(StandardError, "queue is down")

    assert_raises(StandardError) { post clear_ai_cache_rules_url }

    entry = DebugLogEntry.where(category: ClearAiCacheJob::DEBUG_CATEGORY, level: "error").sole
    assert_match "AI cache reset could not be enqueued", entry.message
    assert_equal "StandardError", entry.metadata["error_class"]
  end

  # perform_later swallows ActiveJob::EnqueueError into a false return instead of
  # raising it, which would otherwise log the reset as requested and redirect
  # with a success notice while nothing was queued.
  test "clear_ai_cache records an error when the job is silently not enqueued" do
    ClearAiCacheJob.stubs(:perform_later).with(@user.family).returns(false)

    assert_raises(ActiveJob::EnqueueError) { post clear_ai_cache_rules_url }

    entry = DebugLogEntry.where(category: ClearAiCacheJob::DEBUG_CATEGORY, level: "error").sole
    assert_match "AI cache reset could not be enqueued", entry.message
    assert_equal "ActiveJob::EnqueueError", entry.metadata["error_class"]
    assert_empty DebugLogEntry.where(category: ClearAiCacheJob::DEBUG_CATEGORY, level: "info")
  end

  # When the adapter reports the failure, the yielded job carries the underlying
  # cause — the detail an operator actually needs. The fallback above can only
  # say that nothing was queued.
  test "clear_ai_cache surfaces the queue adapter's error when the job carries one" do
    failed_job = ClearAiCacheJob.new(@user.family)
    failed_job.enqueue_error = ActiveJob::EnqueueError.new("connection refused")
    ClearAiCacheJob.stubs(:perform_later).with(@user.family).yields(failed_job).returns(false)

    error = assert_raises(ActiveJob::EnqueueError) { post clear_ai_cache_rules_url }
    assert_equal "connection refused", error.message

    entry = DebugLogEntry.where(category: ClearAiCacheJob::DEBUG_CATEGORY, level: "error").sole
    assert_match "connection refused", entry.message
    assert_equal "connection refused", entry.metadata["error_message"]
  end

  test "rejects a null byte in a condition instead of returning a server error" do
    assert_no_difference "Rule.count" do
      post rules_url, params: {
        rule: {
          resource_type: "transaction",
          conditions_attributes: {
            "0" => { condition_type: "transaction_name", operator: "like", value: "cof\0fee" }
          },
          actions_attributes: {
            "0" => { action_type: "exclude_transaction" }
          }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "p.text-destructive", text: /Conditions value is invalid/
  end

  test "rejects a null byte when updating an action" do
    rule = rules(:one)
    action = rule.actions.first

    patch rule_url(rule), params: {
      rule: {
        actions_attributes: {
          "0" => { id: action.id, action_type: "set_transaction_name", value: "bad\0value" }
        }
      }
    }

    assert_response :unprocessable_entity
    assert_equal action.value, action.reload.value
  end

  test "rejects a null byte in the condition operator" do
    assert_no_difference "Rule.count" do
      post rules_url, params: {
        rule: {
          resource_type: "transaction",
          conditions_attributes: {
            "0" => { condition_type: "transaction_name", operator: "like\0", value: "coffee" }
          },
          actions_attributes: { "0" => { action_type: "exclude_transaction" } }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/operator is invalid/i, response.body)
  end

  test "rejects a null byte in a nested condition operator" do
    assert_no_difference "Rule.count" do
      post rules_url, params: {
        rule: {
          resource_type: "transaction",
          conditions_attributes: {
            "0" => {
              condition_type: "compound", operator: "and",
              sub_conditions_attributes: {
                "0" => { condition_type: "transaction_name", operator: "like\0", value: "coffee" }
              }
            }
          },
          actions_attributes: { "0" => { action_type: "exclude_transaction" } }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/operator is invalid/i, response.body)
  end

  test "rejects a null byte in the condition type without selecting a different type" do
    post rules_url, params: {
      rule: {
        resource_type: "transaction",
        conditions_attributes: {
          "0" => { condition_type: "transaction_name\0", operator: "like", value: "coffee" }
        },
        actions_attributes: { "0" => { action_type: "exclude_transaction" } }
      }
    }

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/condition type is invalid/i, response.body)
  end

  test "rejects a null byte in the action type without failing to render" do
    assert_no_difference "Rule.count" do
      post rules_url, params: {
        rule: {
          resource_type: "transaction",
          actions_attributes: { "0" => { action_type: "exclude_transaction\0" } }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/action type is invalid/i, response.body)
  end

  test "rejects a null byte when updating the action type" do
    rule = rules(:one)
    action = rule.actions.first
    original_type = action.action_type

    patch rule_url(rule), params: {
      rule: { actions_attributes: { "0" => { id: action.id, action_type: "#{original_type}\0" } } }
    }

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/action type is invalid/i, response.body)
    assert_equal original_type, action.reload.action_type
  end

  test "rejects a null byte in the resource type without failing to render" do
    assert_no_difference "Rule.count" do
      post rules_url, params: {
        rule: {
          resource_type: "transaction\0",
          actions_attributes: { "0" => { action_type: "exclude_transaction" } }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/resource type is invalid/i, response.body)
  end

  # The edit form resubmits every condition and action id with its current
  # values, so these tests submit exactly what the rendered form holds (read back
  # from the edit page) rather than a hand-picked subset.
  test "editing an email rule's condition through the form does not email existing matches" do
    rule, tea = email_rule_with_baseline

    fields = edit_form_fields(rule)
    condition_value = fields.keys.find { |name| name.match?(/\Arule\[conditions_attributes\]\[\d+\]\[value\]\z/) }
    assert_equal "coffee", fields[condition_value]
    patch rule_url(rule), params: fields.merge(condition_value => "house")
    assert_redirected_to rules_url

    emailed = emailed_ids(rule) { perform_enqueued_jobs(only: RuleJob) { post apply_rule_url(rule) } }

    assert_equal [], emailed
    assert_includes NotificationDelivery.where(rule: rule).pluck(:transaction_id), tea.id
  end

  test "saving the form with unchanged conditions does not re-seed" do
    rule, _tea = email_rule_with_baseline
    coffee_bar = Entry.create!(account: @baseline_account, name: "Coffee bar", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new).transaction

    assert_no_difference -> { NotificationDelivery.where(rule: rule).count } do
      patch rule_url(rule), params: edit_form_fields(rule)
    end
    assert_redirected_to rules_url

    emailed = emailed_ids(rule) { perform_enqueued_jobs(only: RuleJob) { post apply_rule_url(rule) } }

    assert_equal [ coffee_bar.id ], emailed, "a match that arrived since the last run is still emailed"
  end

  private
    # A regex condition, so a stubbed timeout reaches the baseline query, and one
    # matching transaction, so a recorded baseline is visible as a delivery.
    # An active regex rule with one match and no email action yet.
    def active_rule_without_email_for(family)
      account = family.accounts.create!(name: "Baseline", balance: 1000, currency: "USD", accountable: Depository.new)
      create_transaction(date: Date.current, account: account, name: "Baseline match zq")

      Rule.create!(
        family: family, resource_type: "transaction", active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: "baseline match zq") ],
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
      )
    end

    # An inactive email rule with one match that arrived after the rule was
    # created, so only switching it on records that match as delivered. (Creating
    # an email action records the matches it already has.)
    def email_rule_for(family)
      account = family.accounts.create!(name: "Baseline", balance: 1000, currency: "USD", accountable: Depository.new)
      rule = Rule.create!(
        family: family, resource_type: "transaction", active: false,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: "baseline match zq") ],
        actions: [ Rule::Action.new(action_type: "send_email_notification") ]
      )
      create_transaction(date: Date.current, account: account, name: "Baseline match zq")
      rule
    end

    # An active email rule matching "Coffee shop", with its baseline taken, and a
    # "Tea house" transaction it does not match yet.
    def email_rule_with_baseline
      family = @user.family
      @baseline_account = family.accounts.create!(name: "Baseline test", balance: 1000, currency: "USD", accountable: Depository.new)
      Entry.create!(account: @baseline_account, name: "Coffee shop", date: 90.days.ago.to_date, amount: 10, currency: "USD", entryable: Transaction.new)
      tea = Entry.create!(account: @baseline_account, name: "Tea house", date: 60.days.ago.to_date, amount: 20, currency: "USD", entryable: Transaction.new).transaction

      rule = family.rules.create!(
        resource_type: "transaction",
        active: true,
        conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "coffee" } ],
        actions_attributes: [ { action_type: "send_email_notification" } ]
      )
      # Rule::Action's create-time seed does not run today (its after_update_commit
      # names the same method and replaces it), so take that baseline here.
      rule.actions.first.send(:seed_notification_baseline)

      [ rule, tea ]
    end

    # The name/value pairs the browser would submit from the rule's edit form:
    # every input and select outside the Stimulus <template>s, checked radios
    # only, and a select's selected option.
    def edit_form_fields(rule)
      get edit_rule_url(rule)
      assert_response :success

      form = Nokogiri::HTML(response.body).at_css("form[action='#{rule_path(rule)}']")
      form.css("input, select").each_with_object({}) do |field, fields|
        next if field.ancestors("template").any? || field["name"].blank?
        next if %w[_method authenticity_token commit].include?(field["name"])
        next if field["type"] == "radio" && !field.has_attribute?("checked")

        fields[field["name"]] = if field.name == "select"
          (field.at_css("option[selected]") || field.at_css("option"))&.[]("value")
        else
          field["value"].to_s
        end
      end
    end

    def emailed_ids(rule)
      before = enqueued_jobs.size
      yield
      enqueued_jobs.drop(before)
        .select { |job| job[:job] == RuleEmailNotificationJob }
        .map { |job| ActiveJob::Arguments.deserialize(job[:args]) }
        .select { |rule_id, _| rule_id == rule.id }
        .flat_map(&:second)
        .sort
    end
end
