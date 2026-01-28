import 'tool_call.dart';

class Message {
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
    return Message(
      id: json['id'].toString(),
      type: json['type'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
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
