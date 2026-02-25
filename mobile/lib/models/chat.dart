import 'message.dart';

class Chat {
  final String id;
  final String title;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Message> messages;
  final int? messageCount;
  final DateTime? lastMessageAt;

  Chat({
    required this.id,
    required this.title,
    this.error,
    required this.createdAt,
    required this.updatedAt,
    this.messages = const [],
    this.messageCount,
    this.lastMessageAt,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    return Chat(
      id: json['id'].toString(),
      title: json['title'] as String,
      error: json['error'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      messages: json['messages'] != null
          ? (json['messages'] as List)
              .map((m) => Message.fromJson(m as Map<String, dynamic>))
              .toList()
          : [],
      messageCount: json['message_count'] as int?,
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'error': error,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'messages': messages.map((m) => m.toJson()).toList(),
      'message_count': messageCount,
      'last_message_at': lastMessageAt?.toIso8601String(),
    };
  }

  static const String defaultTitle = 'New Chat';
  static const int maxTitleLength = 80;

  static String generateTitle(String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.length <= maxTitleLength) return trimmed;
    return trimmed.substring(0, maxTitleLength);
  }

  bool get hasDefaultTitle => title == defaultTitle;

  Chat copyWith({
    String? id,
    String? title,
    String? error,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Message>? messages,
    int? messageCount,
    DateTime? lastMessageAt,
  }) {
    return Chat(
      id: id ?? this.id,
      title: title ?? this.title,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
      messageCount: messageCount ?? this.messageCount,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    );
  }
}
