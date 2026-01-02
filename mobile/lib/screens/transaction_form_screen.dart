import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/account.dart';
import '../providers/auth_provider.dart';
import '../services/transactions_service.dart';

class TransactionFormScreen extends StatefulWidget {
  final Account account;

  const TransactionFormScreen({
    super.key,
    required this.account,
  });

  @override
  State<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends State<TransactionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _dateController = TextEditingController();
  final _nameController = TextEditingController();
  final _transactionsService = TransactionsService();

  String _nature = 'expense';
  bool _showMoreFields = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // Set default values
    final now = DateTime.now();
    final formattedDate = DateFormat('yyyy/MM/dd').format(now);
    _dateController.text = formattedDate;
    _nameController.text = 'SureApp';
  }

  @override
  void dispose() {
    _amountController.dispose();
    _dateController.dispose();
    _nameController.dispose();
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

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final accessToken = await authProvider.getValidAccessToken();

      if (accessToken == null) {
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

      final result = await _transactionsService.createTransaction(
        accessToken: accessToken,
        accountId: widget.account.id,
        name: _nameController.text.trim(),
        date: apiDate,
        amount: _amountController.text.trim(),
        currency: widget.account.currency,
        nature: _nature,
        notes: 'This transaction via mobile app.',
      );

      if (mounted) {
        if (result['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Transaction created successfully'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context, true); // Return true to indicate success
        } else {
          final error = result['error'] ?? 'Failed to create transaction';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: Colors.red,
            ),
          );

          if (error == 'unauthorized') {
            await authProvider.logout();
          }
        }
      }
    } catch (e) {
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
                      'New Transaction',
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
                              : const Text('Create Transaction'),
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
