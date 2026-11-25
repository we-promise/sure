require "test_helper"

# A chat turn's tools make AI calls of their own (search_family_files embeds its query). Chat holds
# its place at the gate per request, so a nested call to the same host never waits for its own turn.
class AiNestedCallTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Asks for one document search, then answers.
  class SearchingLlm
    include Provider::LlmConcept

    attr_reader :holders

    def initialize(respond) = (@respond, @holders = respond, [])
    def supports_responses_endpoint? = false

    def chat_response(_prompt, streamer:, **)
      @holders << Ai::Gate.holder
      if @holders.size == 1
        request = ChatFunctionRequest.new(id: "1", call_id: "1", function_name: "search_family_files", function_args: { query: "tax return" }.to_json)
        return @respond.(ChatResponse.new(id: "1", model: "qwen3-8b", messages: [], function_requests: [ request ]))
      end

      streamer.call(ChatStreamChunk.new(type: "output_text", data: "Found it.", usage: nil))
      @respond.(ChatResponse.new(id: "2", model: "qwen3-8b", messages: [ ChatMessage.new(id: "2", output_text: "Found it.") ], function_requests: []))
    end
  end

  # Searches by embedding the query, as Pgvector does.
  class EmbeddingAdapter
    include ProviderTestHelper

    def search(query:, family:, user:, **)
      Ai::Embeddings.query(query, family:, user:)
      provider_success_response([])
    end
  end

  setup do
    @user = users(:family_admin)
    @user.family.update!(assistant_type: "builtin", vector_store_id: "store")
    @endpoint = ai_endpoint(name: "gpu", base_url: "http://gpu.local:8080/v1", location: :local)
    route_chat_and_embeddings_to @endpoint
    VectorStore.stubs(:adapter).returns(EmbeddingAdapter.new)
    Family.any_instance.stubs(:vector_store_adapter).returns(EmbeddingAdapter.new)

    @llm = SearchingLlm.new(method(:provider_success_response))
    Assistant::Builtin.any_instance.stubs(:get_model_provider).returns(@llm)
    @chat = @user.chats.create!(title: "Taxes")
    @message = UserMessage.create!(chat: @chat, content: "Find my tax return", ai_model: "qwen3-8b")
    @reply = @chat.messages.find_by!(type: "AssistantMessage")
  end

  test "a chat turn whose tool embeds on the chat's own host, with one place, completes" do
    nested = nil
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return do
      nested = [ Ai::Gate.holder.lane, Ai::Gate.holder.job ]
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { object: "list", model: "nomic", data: [ { index: 0, embedding: [ 0.1, 0.2, 0.3 ] } ], usage: { prompt_tokens: 2, total_tokens: 2 } }.to_json }
    end

    Timeout.timeout(10) { AssistantResponseJob.perform_now(@message, @reply) }

    assert_equal "Found it.", @reply.reload.content
    assert_equal 2, @llm.holders.compact.uniq.size, "each round holds a place of its own"
    assert_equal [ "reply:#{@reply.id}" ], @llm.holders.map(&:job).uniq, "under the reply's own id"
    assert_equal [ :interactive, "chat:#{@chat.id}" ], nested, "the nested call runs in chat's lane, under the chat's correlation id"
    assert_empty Ai::Sequencer.gate_for(@endpoint).holders
  end

  test "a reply's bubble says Thinking as each of its requests gets its place" do
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return(status: 500)
    held = []
    Chat.any_instance.stubs(:broadcast_update).with { |opts| held << [ opts[:html], Ai::Gate.holder.present? ] if opts[:html].is_a?(String) }

    AssistantResponseJob.perform_now(@message, @reply)

    assert_equal [ [ "Thinking ...", false ], [ "Thinking ...", true ], [ "Thinking ...", true ] ], held, "the job's start, then each request"
  end

  test "the time a chat request waits for its place isn't the reply's" do
    gate = Ai::Sequencer.gate_for(@endpoint)
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return(status: 500)
    released = Queue.new
    other = Thread.new { gate.hold(:interactive) { released.pop(timeout: 5) } }
    Timeout.timeout(5) { sleep 0.01 until gate.holders.any? }
    moved = nil
    AssistantMessage.any_instance.stubs(:waited!).with { |seconds| moved ||= seconds }
    reply = Thread.new { AssistantResponseJob.perform_now(@message, @reply) }
    Timeout.timeout(5) { sleep 0.01 until gate.waiters.any? }
    sleep 0.3
    released << true
    reply.join(10)

    assert_operator moved, :>=, 0.3
  ensure
    released << true
    [ other, reply ].compact.each { _1.join(2) }
  end

  test "the watchdog doesn't give up on a reply between its place and its time moving" do
    Sidekiq.stubs(:server?).returns(true)
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return(status: 500)
    given_up = []
    AssistantMessage.any_instance.stubs(:waited!).with do |_seconds|
      AssistantMessage.where(id: @reply.id).update_all(created_at: 10.minutes.ago, updated_at: 5.minutes.ago)
      given_up << @chat.handle_undelivered_response!(AssistantMessage.find(@reply.id))
    end

    AssistantResponseJob.perform_now(@message, @reply)

    assert_equal [ false, false ], given_up, "in either of its requests"
    assert_equal "Found it.", @reply.reload.content
  end

  test "a chat request ends its own user's typing hold, and no one else's" do
    ChatReservation.new([ @endpoint ], lanes: %i[prompt background], user: users(:family_member)).hold!
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return(status: 500)

    AssistantResponseJob.perform_now(@message, @reply)

    assert ChatReservation.held?("gpu.local:8080", :prompt)
  end

  test "a chat request ends the typing hold on its host" do
    ChatReservation.new([ @endpoint ], lanes: %i[prompt background], user: users(:family_admin)).hold!
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return(status: 500)

    AssistantResponseJob.perform_now(@message, @reply)

    assert_not ChatReservation.held?("gpu.local:8080", :background)
  end

  test "a chat request interrupts the background request its host is running" do
    gate = Ai::Sequencer.gate_for(@endpoint)
    preempted = nil
    running = Thread.new do
      gate.hold(:background) do
        sleep 0.01 until Ai::Gate.holder.preempted?
        preempted = true
      end
    end
    Timeout.timeout(5) { sleep 0.01 until gate.holders.any? }
    stub_request(:post, "http://gpu.local:8080/v1/embeddings").to_return(status: 500)

    Timeout.timeout(10) { AssistantResponseJob.perform_now(@message, @reply) }

    assert preempted
    assert_equal "Found it.", @reply.reload.content
  ensure
    running.kill.join(2)
  end

  test "a cloud chat holds no place" do
    use_ai_routes
    stub_request(:post, "http://embed.local:8081/v1/embeddings").to_return(status: 500)

    AssistantResponseJob.perform_now(@message, @reply)

    assert_equal [ nil, nil ], @llm.holders
  end

  test "an external assistant on the local network has no gate: it calls its own models" do
    agent = ai_endpoint(name: "agent", base_url: "http://agent.local:18789/v1", location: :local, agent: true, agent_settings: { allowed_emails: [] })
    Ai::Config.override = AiTestHelper.build_ai_config([ ai_model(name: "openclaw/main", endpoint: agent) ], { chat: %w[agent/openclaw/main] })
    @user.family.update!(assistant_type: "external")

    assert_equal "agent", Ai.plan(:chat, family: @user.family, user: @user).route.endpoint.name
    assert_nil Ai::Sequencer.chat_endpoint(@user)
    assert Ai::Sequencer.external_chat?(@user)
    assert_empty Ai::Sequencer.local_endpoints
  end

  test "an external assistant's turn holds background requests off every local host and ends the typing hold" do
    use_ai_routes
    gpu = AiTestHelper.test_config.endpoint(:gpu)
    ChatReservation.new([ gpu ], lanes: %i[background], user: users(:family_admin)).hold!
    @user.family.update!(assistant_type: "external")
    Assistant::External.stubs(configured?: true, allowed_user?: true)
    refused = nil
    client = Object.new
    client.define_singleton_method(:chat) do |**, &answer|
      refused = %i[gpu embed].map do |name|
        Ai::Sequencer.gate_for(AiTestHelper.test_config.endpoint(name)).hold(:background) { :ran }
      rescue Ai::Error::Busy
        :refused
      end
      answer.call("Hello")
      nil
    end
    Assistant::External.any_instance.stubs(:build_client).returns(client)

    AssistantResponseJob.perform_now(UserMessage.find(@message.id), @reply)

    assert_equal %i[refused refused], refused
    assert_equal "Hello", @reply.reload.content
    assert_equal :ran, Ai::Sequencer.gate_for(gpu).hold(:background) { :ran }, "the turn is over, and the message ended the hold"
  end

  test "background requests start again after an external assistant's turn fails" do
    use_ai_routes
    assert_raises(RuntimeError) { Ai::Sequencer.external_chat(@user) { raise "boom" } }

    assert_equal :ran, Ai::Sequencer.gate_for(AiTestHelper.test_config.endpoint(:gpu)).hold(:background) { :ran }
  end

  private
    def route_chat_and_embeddings_to(endpoint)
      chat = ai_model(name: "qwen3-8b", endpoint:, capabilities: AiTestHelper::LLM_CAPABILITIES)
      embedder = ai_model(name: "nomic", endpoint:, capabilities: %i[embedding], embedding_dimensions: 3)
      Ai::Config.override = AiTestHelper.build_ai_config([ chat, embedder ], { chat: %w[gpu/qwen3-8b], embed: %w[gpu/nomic] }, vector_store_backend: :pgvector)
    end
end
