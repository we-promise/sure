import 'tool_call.dart';

class Message {
  /// Known LLM special tokens that may leak into responses (strip from display).
  /// Includes ASCII ChatML (<|...|>) and DeepSeek full-width variants (<｜...｜>).
  static const _llmTokenPatterns = [
    '<|start_of_sentence|>',
    '<|im_start|>',
    '<|im_end|>',
    '<|endoftext|>',
    '</s>',
    // DeepSeek full-width pipe variants (U+FF5C ｜)
    '<\uFF5Cstart_of_sentence\uFF5C>',
    '<\uFF5Cim_start\uFF5C>',
    '<\uFF5Cim_end\uFF5C>',
    '<\uFF5Cendoftext\uFF5C>',
  ];

  /// Removes LLM tokens and trims trailing whitespace from assistant content.
  static String sanitizeContent(String content) {
    var out = content;
    for (final token in _llmTokenPatterns) {
      out = out.replaceAll(token, '');
    }
    out = out.replaceAll(RegExp(r'<\|[^|]*\|>'), '');
    out = out.replaceAll(RegExp('<\u{FF5C}[^\u{FF5C}]*\u{FF5C}>'), '');
    return out.trim();
  }

  final String id;
  final String type;
  final String role;
  final String content;
  final String? model;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ToolCall>? toolCalls;

  Message({
    required this.id,
    required this.type,
    required this.role,
    required this.content,
    this.model,
    required this.createdAt,
    required this.updatedAt,
    this.toolCalls,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'] as String;
    final role = json['role'] as String;
    final content = role == 'assistant' ? sanitizeContent(rawContent) : rawContent;
    return Message(
      id: json['id'].toString(),
      type: json['type'] as String,
      role: role,
      content: content,
      model: json['model'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      toolCalls: json['tool_calls'] != null
          ? (json['tool_calls'] as List)
              .map((tc) => ToolCall.fromJson(tc as Map<String, dynamic>))
              .toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'role': role,
      'content': content,
      'model': model,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'tool_calls': toolCalls?.map((tc) => tc.toJson()).toList(),
    };
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
}
