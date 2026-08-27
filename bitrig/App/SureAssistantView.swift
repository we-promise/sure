import SwiftUI

struct SureAssistantView: View {
  @Environment(SureStore.self) private var store
  @State private var draft = ""
  @FocusState private var composerFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 14) {
            if store.messages.isEmpty {
              VStack(spacing: 16) {
                Image(systemName: "sparkles")
                  .font(.system(size: 46))
                  .foregroundStyle(.tint)
                Text("Ask about your money")
                  .font(.title2.bold())
                Text("Sure’s Assistant can analyze your live accounts, spending, budgets, investments, and insights.")
                  .multilineTextAlignment(.center)
                  .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                  suggestion("What should I pay attention to this month?")
                  suggestion("How diversified are my investments?")
                  suggestion("Find easy ways I could cut costs")
                }
              }
              .frame(maxWidth: 560)
              .padding(.horizontal, 24)
              .padding(.top, 52)
            } else {
              ForEach(store.messages) { message in
                SureMessageBubble(message: message)
                  .id(message.id)
              }
              if store.isAssistantThinking {
                HStack(spacing: 8) {
                  ProgressView()
                  Text("Thinking…")
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .id("thinking")
              }
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical)
        }
        .onChange(of: store.messages.count) {
          if let id = store.messages.last?.id {
            withAnimation(.smooth) { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
        .onChange(of: store.isAssistantThinking) {
          if store.isAssistantThinking {
            withAnimation(.smooth) { proxy.scrollTo("thinking", anchor: .bottom) }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        composer
      }
      .navigationTitle(store.selectedChat?.title ?? "Assistant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Picker("Conversation", selection: chatSelection) {
            Text("New conversation").tag(Optional<String>.none)
            ForEach(store.chats) { chat in
              Text(chat.title).tag(Optional(chat.id))
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()

          Button("New conversation", systemImage: "square.and.pencil") {
            store.newChat()
          }
          .labelStyle(.iconOnly)
        }
      }
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Message Sure Assistant", text: $draft, axis: .vertical)
        .lineLimit(1...5)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .focused($composerFocused)
        .submitLabel(.send)
        .onSubmit(send)
      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(Color.sureIndigo, in: .circle)
      }
      .accessibilityLabel("Send message")
      .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAssistantThinking)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var chatSelection: Binding<String?> {
    Binding {
      store.selectedChat?.id
    } set: { id in
      guard let id, let chat = store.chats.first(where: { $0.id == id }) else {
        store.newChat()
        return
      }
      Task { await store.loadChat(chat) }
    }
  }

  private func suggestion(_ text: String) -> some View {
    Button {
      draft = text
      send()
    } label: {
      HStack {
        Text(text)
          .multilineTextAlignment(.leading)
        Spacer()
        Image(systemName: "arrow.up.right")
      }
      .padding(14)
      .background(Color.sureIndigo.opacity(0.08), in: .rect(cornerRadius: 14))
    }
    .buttonStyle(.plain)
  }

  private func send() {
    let message = draft
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    draft = ""
    Task { await store.sendMessage(message) }
  }
}

struct SureMessageBubble: View {
  var message: SureMessage

  var body: some View {
    HStack {
      if message.isUser { Spacer(minLength: 44) }
      Text(LocalizedStringKey(message.content))
        .textSelection(.enabled)
        .padding(14)
        .foregroundStyle(message.isUser ? Color.white : Color.primary)
        .background(
          message.isUser ? AnyShapeStyle(Color.sureIndigo) : AnyShapeStyle(.background.secondary),
          in: .rect(cornerRadius: 18)
        )
      if !message.isUser { Spacer(minLength: 44) }
    }
    .padding(.horizontal)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message.isUser ? "You: \(message.content)" : "Sure Assistant: \(message.content)")
  }
}
