import '../utils/split_math.dart';
import 'transaction.dart';

/// One child of a split, as returned by `GET /api/v1/transactions/:id/split`.
///
/// [transaction] carries the regular transaction payload (name, category,
/// display-formatted amount). [amountDecimal] is the exact stored amount,
/// which is what a replacement split has to send back.
class TransactionSplitChild {
  final Transaction transaction;
  final String amountDecimal;
  final bool excluded;

  const TransactionSplitChild({
    required this.transaction,
    required this.amountDecimal,
    this.excluded = false,
  });

  factory TransactionSplitChild.fromJson(Map<String, dynamic> json) {
    return TransactionSplitChild(
      transaction: Transaction.fromJson(json),
      amountDecimal: json['amount_decimal']?.toString() ?? '0',
      excluded: json['excluded'] == true,
    );
  }

  String? get id => transaction.id;
  String get name => transaction.name;
  String? get categoryId => transaction.categoryId;
  String? get categoryName => transaction.categoryName;

  /// Exact amount in [SplitMath.scale] units, using the API sign convention
  /// (expenses positive, income negative).
  BigInt get amountUnits => SplitMath.parseUnits(amountDecimal) ?? BigInt.zero;
}

/// A split parent and its children.
class TransactionSplit {
  final String transactionId;

  /// Display-formatted parent amount (rounded to currency precision).
  final String amount;

  /// Exact stored parent amount; the children must sum to this.
  final String amountDecimal;
  final String currency;
  final List<TransactionSplitChild> children;

  TransactionSplit({
    required this.transactionId,
    required this.amount,
    required this.amountDecimal,
    required this.currency,
    required List<TransactionSplitChild> children,
  }) : children = List.unmodifiable(children);

  factory TransactionSplit.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'];
    return TransactionSplit(
      transactionId: json['transaction_id']?.toString() ?? '',
      amount: json['amount']?.toString() ?? '',
      amountDecimal: json['amount_decimal']?.toString() ?? '0',
      currency: json['currency']?.toString() ?? '',
      children: rawChildren is List
          ? rawChildren
              .whereType<Map>()
              .map((child) => TransactionSplitChild.fromJson(
                    Map<String, dynamic>.from(child),
                  ))
              .toList()
          : const [],
    );
  }

  BigInt get amountUnits => SplitMath.parseUnits(amountDecimal) ?? BigInt.zero;

  List<String> get childIds =>
      children.map((c) => c.id).whereType<String>().toList();
}

/// One row the user submits when creating or replacing a split.
///
/// [amount] is a plain decimal string in the API's sign convention (same sign
/// as the parent's stored amount).
class SplitRowInput {
  final String name;
  final String amount;
  final String? categoryId;
  final bool excluded;

  const SplitRowInput({
    required this.name,
    required this.amount,
    this.categoryId,
    this.excluded = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'amount': amount,
        'category_id': categoryId,
        if (excluded) 'excluded': true,
      };
}
