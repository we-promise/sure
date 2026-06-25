import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/account.dart';
import '../models/category.dart' as models;
import '../providers/auth_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/log_service.dart';
import '../services/connectivity_service.dart';
import '../utils/amount_parser.dart';
import '../widgets/sure_segmented_control.dart';
import '../l10n/app_localizations.dart';

class TransactionFormScreen extends StatefulWidget {
  final Account account;

  const TransactionFormScreen({super.key, required this.account});

  @override
  State<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends State<TransactionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _dateController = TextEditingController();
  final _nameController = TextEditingController();
  final _log = LogService.instance;

  String _nature = 'expense';
  bool _showMoreFields = false;
  bool _isSubmitting = false;
  models.Category? _selectedCategory;

  @override
  void initState() {
    super.initState();
    // Set default values
    final now = DateTime.now();
    final formattedDate = DateFormat('yyyy/MM/dd').format(now);
    _dateController.text = formattedDate;
    _nameController.text = 'SureApp';
    _fetchCategories();
  }

  Future<void> _fetchCategories() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final categoriesProvider = Provider.of<CategoriesProvider>(
      context,
      listen: false,
    );
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken != null) {
      categoriesProvider.fetchCategories(accessToken: accessToken);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _dateController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  String? _validateAmount(String? value) {
    final l = AppLocalizations.of(context);
    if (value == null || value.trim().isEmpty) {
      return l.transactionFormAmountRequiredPrompt;
    }

    final double amount;
    try {
      amount = AmountParser.parse(value, locale: _currentLocaleName()).value;
    } on FormatException {
      return l.transactionFormAmountInvalidNumber;
    }

    if (amount <= 0) {
      return l.transactionFormAmountTooSmall;
    }

    return null;
  }

  String _currentLocaleName() {
    return Localizations.maybeLocaleOf(context)?.toString() ??
        Intl.getCurrentLocale();
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

    _log.info('TransactionForm', 'Starting transaction creation...');

    final l = AppLocalizations.of(context);

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final transactionsProvider = Provider.of<TransactionsProvider>(
        context,
        listen: false,
      );
      final accessToken = await authProvider.getValidAccessToken();

      if (accessToken == null) {
        _log.warning(
          'TransactionForm',
          'Access token is null, session expired',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.transactionFormSessionExpired),
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
      final canonicalAmount = AmountParser.canonicalize(
        _amountController.text,
        locale: _currentLocaleName(),
      );

      _log.info(
        'TransactionForm',
        'Calling TransactionsProvider.createTransaction (offline-first)',
      );

      // Use TransactionsProvider for offline-first transaction creation
      final success = await transactionsProvider.createTransaction(
        accessToken: accessToken,
        accountId: widget.account.id,
        name: _nameController.text.trim(),
        date: apiDate,
        amount: canonicalAmount,
        currency: widget.account.currency,
        nature: _nature,
        notes: 'This transaction via mobile app.',
        categoryId: _selectedCategory?.id,
        categoryName: _selectedCategory?.name,
      );

      if (mounted) {
        if (success) {
          _log.info(
            'TransactionForm',
            'Transaction created successfully (saved locally)',
          );

          // Check current connectivity status to show appropriate message
          final connectivityService = Provider.of<ConnectivityService>(
            context,
            listen: false,
          );
          final isOnline = connectivityService.isOnline;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isOnline
                    ? l.transactionFormCreateSuccessOnline
                    : l.transactionFormCreateSuccessOffline,
              ),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context, true); // Return true to indicate success
        } else {
          _log.error('TransactionForm', 'Failed to create transaction');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.transactionFormCreateFailed),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      _log.error(
        'TransactionForm',
        'Exception during transaction creation: $e',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.transactionFormGenericError(e.toString())),
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
    final l = AppLocalizations.of(context);
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l.transactionFormNewTitle,
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.account.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${widget.account.balance} ${widget.account.currency}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color:
                                                  colorScheme.onSurfaceVariant,
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
                          l.transactionFormTypeLabel,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        SureSegmentedControl<String>(
                          selected: _nature,
                          onChanged: (value) {
                            setState(() {
                              _nature = value;
                            });
                          },
                          segments: [
                            SureSegment<String>(
                              value: 'expense',
                              label: l.transactionFormTypeExpense,
                              icon: const Icon(Icons.arrow_downward),
                            ),
                            SureSegment<String>(
                              value: 'income',
                              label: l.transactionFormTypeIncome,
                              icon: const Icon(Icons.arrow_upward),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Amount field
                        TextFormField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: '${l.transactionFormAmountLabel} *',
                            prefixIcon: const Icon(Icons.attach_money),
                            suffixText: widget.account.currency,
                            helperText: l.transactionFormAmountHelper,
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
                          icon: Icon(
                            _showMoreFields
                                ? Icons.expand_less
                                : Icons.expand_more,
                          ),
                          label: Text(
                            _showMoreFields
                                ? l.transactionFormLess
                                : l.transactionFormMore,
                          ),
                        ),

                        // Optional fields (shown when More is clicked)
                        if (_showMoreFields) ...[
                          const SizedBox(height: 16),

                          // Date field
                          TextFormField(
                            controller: _dateController,
                            readOnly: true,
                            decoration: InputDecoration(
                              labelText: l.transactionFormDateLabel,
                              prefixIcon: const Icon(Icons.calendar_today),
                              helperText: l.transactionFormDateHelper,
                            ),
                            onTap: _selectDate,
                          ),
                          const SizedBox(height: 16),

                          // Name field
                          TextFormField(
                            controller: _nameController,
                            decoration: InputDecoration(
                              labelText: l.transactionFormNameLabel,
                              prefixIcon: const Icon(Icons.label),
                              helperText: l.transactionFormNameHelper,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Category picker
                          Consumer<CategoriesProvider>(
                            builder: (context, categoriesProvider, _) {
                              if (categoriesProvider.isLoading) {
                                return InputDecorator(
                                  decoration: InputDecoration(
                                    labelText: l.transactionFormCategoryLabel,
                                    prefixIcon: const Icon(Icons.category),
                                  ),
                                  child: Text(
                                    l.transactionFormCategoryLoading,
                                  ),
                                );
                              }

                              final categories = categoriesProvider.categories;

                              return DropdownButtonFormField<String?>(
                                value: _selectedCategory?.id,
                                decoration: InputDecoration(
                                  labelText: l.transactionFormCategoryLabel,
                                  prefixIcon: const Icon(Icons.category),
                                  helperText: l.transactionFormCategoryHelper,
                                ),
                                isExpanded: true,
                                items: [
                                  DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text(l.transactionFormNoCategory),
                                  ),
                                  ...categories.map((category) {
                                    return DropdownMenuItem<String?>(
                                      value: category.id,
                                      child: Text(category.displayName),
                                    );
                                  }),
                                ],
                                onChanged: (value) {
                                  setState(() {
                                    if (value == null) {
                                      _selectedCategory = null;
                                    } else {
                                      _selectedCategory = categories.firstWhere(
                                        (c) => c.id == value,
                                      );
                                    }
                                  });
                                },
                              );
                            },
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
                              : Text(l.transactionFormCreateButton),
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
