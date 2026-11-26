class ReceiptScan {
  final String id;
  final String status;
  final String accountId;
  final String? transactionId;
  final List<Map<String, dynamic>> reviewReasons;

  const ReceiptScan({
    required this.id,
    required this.status,
    required this.accountId,
    this.transactionId,
    this.reviewReasons = const [],
  });

  factory ReceiptScan.fromJson(Map<String, dynamic> json) {
    return ReceiptScan(
      id: json['id'].toString(),
      status: json['status']?.toString() ?? 'processing',
      accountId: json['account_id'].toString(),
      transactionId: json['transaction_id']?.toString(),
      reviewReasons: (json['review_reasons'] as List? ?? const [])
          .whereType<Map>()
          .map((reason) => Map<String, dynamic>.from(reason))
          .toList(),
    );
  }
}
