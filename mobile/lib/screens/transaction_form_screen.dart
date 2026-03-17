import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/account.dart';
import '../models/transaction.dart';
import '../providers/auth_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/log_service.dart';
import '../services/connectivity_service.dart';

class TransactionFormScreen extends StatefulWidget {
  final Account account;
  final Transaction? transaction; // If provided, we're in edit mode

  const TransactionFormScreen({
    super.key,
    required this.account,
    this.transaction,
  });

  @override
  State<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends State<TransactionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _dateController = TextEditingController();
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();
  final _log = LogService.instance;

  String _nature = 'expense';
  bool _showMoreFields = false;
  bool _isSubmitting = false;

  bool get _isEditMode => widget.transaction != null;

  @override
  void initState() {
    super.initState();

    if (_isEditMode) {
      final t = widget.transaction!;
      _amountController.text = t.rawAmount;
      _nameController.text = t.name;
      _nature = t.nature;
      _notesController.text = t.notes ?? '';
      _showMoreFields = true; // Expand fields in edit mode

      // Parse existing date (yyyy-MM-dd from API) to display format
      try {
        final parsed = DateFormat('yyyy-MM-dd').parse(t.date);
        _dateController.text = DateFormat('yyyy/MM/dd').format(parsed);
      } catch (_) {
        _dateController.text = t.date;
      }
    } else {
      final now = DateTime.now();
      _dateController.text = DateFormat('yyyy/MM/dd').format(now);
      _nameController.text = 'SureApp';
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _dateController.dispose();
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String? _validateAmount(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter an amount';
    }

    final amount = double.tryParse(value.trim());
    if (amount == null) {
      return 'Please enter a valid number';
    }

    if (amount <= 0) {
      return 'Amount must be greater than 0';
    }

    return null;
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _dateController.text = DateFormat('yyyy/MM/dd').format(picked);
      });
    }
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    _log.info('TransactionForm', _isEditMode ? 'Starting transaction update...' : 'Starting transaction creation...');

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final transactionsProvider = Provider.of<TransactionsProvider>(context, listen: false);
      final accessToken = await authProvider.getValidAccessToken();

      if (accessToken == null) {
        _log.warning('TransactionForm', 'Access token is null, session expired');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session expired. Please login again.'),
              backgroundColor: Colors.red,
            ),
          );
          await authProvider.logout();
        }
        return;
      }

      // Convert date format from yyyy/MM/dd to yyyy-MM-dd
      final parsedDate = DateFormat('yyyy/MM/dd').parse(_dateController.text);
      final apiDate = DateFormat('yyyy-MM-dd').format(parsedDate);

      final notes = _notesController.text.trim().isEmpty
          ? (_isEditMode ? null : 'This transaction via mobile app.')
          : _notesController.text.trim();

      bool success;

      if (_isEditMode) {
        success = await transactionsProvider.updateTransaction(
          accessToken: accessToken,
          transactionId: widget.transaction!.id!,
          name: _nameController.text.trim(),
          date: apiDate,
          amount: _amountController.text.trim(),
          currency: widget.account.currency,
          nature: _nature,
          notes: notes,
        );
      } else {
        success = await transactionsProvider.createTransaction(
          accessToken: accessToken,
          accountId: widget.account.id,
          name: _nameController.text.trim(),
          date: apiDate,
          amount: _amountController.text.trim(),
          currency: widget.account.currency,
          nature: _nature,
          notes: notes,
        );
      }

      if (mounted) {
        if (success) {
          final connectivityService = Provider.of<ConnectivityService>(context, listen: false);
          final isOnline = connectivityService.isOnline;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _isEditMode
                    ? 'Transaction updated successfully'
                    : isOnline
                        ? 'Transaction created successfully'
                        : 'Transaction saved (will sync when online)'
              ),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context, true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isEditMode ? 'Failed to update transaction' : 'Failed to create transaction'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      _log.error('TransactionForm', 'Exception during transaction ${_isEditMode ? "update" : "creation"}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _isEditMode ? 'Edit Transaction' : 'New Transaction',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Form content
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: EdgeInsets.only(
                    left: 24,
                    right: 24,
                    top: 16,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Account info card
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.account_balance_wallet,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.account.name,
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${widget.account.balance} ${widget.account.currency}',
                                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Transaction type selection
                        Text(
                          'Type',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment<String>(
                              value: 'expense',
                              label: Text('Expense'),
                              icon: Icon(Icons.arrow_downward),
                            ),
                            ButtonSegment<String>(
                              value: 'income',
                              label: Text('Income'),
                              icon: Icon(Icons.arrow_upward),
                            ),
                          ],
                          selected: {_nature},
                          onSelectionChanged: (Set<String> newSelection) {
                            setState(() {
                              _nature = newSelection.first;
                            });
                          },
                        ),
                        const SizedBox(height: 24),

                        // Amount field
                        TextFormField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: 'Amount *',
                            prefixIcon: const Icon(Icons.attach_money),
                            suffixText: widget.account.currency,
                            helperText: 'Required',
                          ),
                          validator: _validateAmount,
                        ),
                        const SizedBox(height: 24),

                        // More button
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _showMoreFields = !_showMoreFields;
                            });
                          },
                          icon: Icon(_showMoreFields ? Icons.expand_less : Icons.expand_more),
                          label: Text(_showMoreFields ? 'Less' : 'More'),
                        ),

                        // Optional fields (shown when More is clicked)
                        if (_showMoreFields) ...[
                          const SizedBox(height: 16),

                          // Date field
                          TextFormField(
                            controller: _dateController,
                            readOnly: true,
                            decoration: const InputDecoration(
                              labelText: 'Date',
                              prefixIcon: Icon(Icons.calendar_today),
                              helperText: 'Optional (default: today)',
                            ),
                            onTap: _selectDate,
                          ),
                          const SizedBox(height: 16),

                          // Name field
                          TextFormField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              prefixIcon: Icon(Icons.label),
                              helperText: 'Optional (default: SureApp)',
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Notes field
                          TextFormField(
                            controller: _notesController,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: 'Notes',
                              prefixIcon: Icon(Icons.notes),
                              helperText: 'Optional',
                            ),
                          ),
                        ],

                        const SizedBox(height: 32),

                        // Submit button
                        ElevatedButton(
                          onPressed: _isSubmitting ? null : _handleSubmit,
                          child: _isSubmitting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(_isEditMode ? 'Update Transaction' : 'Create Transaction'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
