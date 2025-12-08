import 'package:flutter/foundation.dart';
import '../models/transaction.dart';
import '../services/transactions_service.dart';

class TransactionsProvider with ChangeNotifier {
  final TransactionsService _transactionsService = TransactionsService();

  List<Transaction> _transactions = [];
  bool _isLoading = false;
  String? _error;

  List<Transaction> get transactions => _transactions;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchTransactions({
    required String accessToken,
    String? accountId,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    final result = await _transactionsService.getTransactions(
      accessToken: accessToken,
      accountId: accountId,
    );

    _isLoading = false;

    if (result['success']) {
      _transactions = result['transactions'];
      _error = null;
    } else {
      _error = result['error'];
    }

    notifyListeners();
  }

  Future<bool> deleteTransaction({
    required String accessToken,
    required String transactionId,
  }) async {
    final result = await _transactionsService.deleteTransaction(
      accessToken: accessToken,
      transactionId: transactionId,
    );

    if (result['success']) {
      _transactions.removeWhere((t) => t.id == transactionId);
      notifyListeners();
      return true;
    } else {
      _error = result['error'];
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteMultipleTransactions({
    required String accessToken,
    required List<String> transactionIds,
  }) async {
    final result = await _transactionsService.deleteMultipleTransactions(
      accessToken: accessToken,
      transactionIds: transactionIds,
    );

    if (result['success']) {
      _transactions.removeWhere((t) => transactionIds.contains(t.id));
      notifyListeners();
      return true;
    } else {
      _error = result['error'];
      notifyListeners();
      return false;
    }
  }

  void clearTransactions() {
    _transactions = [];
    _error = null;
    notifyListeners();
  }
}
