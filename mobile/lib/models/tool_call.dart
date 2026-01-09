class ToolCall {
  final String id;
  final String functionName;
  final Map<String, dynamic> functionArguments;
  final Map<String, dynamic>? functionResult;
  final DateTime createdAt;

  ToolCall({
    required this.id,
    required this.functionName,
    required this.functionArguments,
    this.functionResult,
    required this.createdAt,
  });

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      id: json['id'] as String,
      functionName: json['function_name'] as String,
      functionArguments: json['function_arguments'] as Map<String, dynamic>,
      functionResult: json['function_result'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'function_name': functionName,
      'function_arguments': functionArguments,
      'function_result': functionResult,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
