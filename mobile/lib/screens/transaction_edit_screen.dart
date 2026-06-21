import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/category.dart' as models;
import '../models/merchant.dart';
import '../models/offline_transaction.dart';
import '../models/transaction_tag.dart';
import '../providers/auth_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/merchants_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/transactions_provider.dart';
import '../l10n/app_localizations.dart';

class TransactionEditScreen extends StatefulWidget {
  final OfflineTransaction transaction;

  const TransactionEditScreen({super.key, required this.transaction});

  @override
  State<TransactionEditScreen> createState() => _TransactionEditScreenState();
}

class _TransactionEditScreenState extends State<TransactionEditScreen> {
  static const _maxNameLength = 255;
  static const _maxNotesLength = 2000;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _notesController;
  String? _selectedCategoryId;
  String? _selectedMerchantId;
  late Set<String> _selectedTagIds;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.transaction.name);
    _notesController = TextEditingController(
      text: widget.transaction.notes ?? '',
    );
    _selectedCategoryId = widget.transaction.categoryId;
    _selectedMerchantId = widget.transaction.merchantId;
    _selectedTagIds = widget.transaction.tagIds.toSet();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMetadata());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final categoriesProvider = Provider.of<CategoriesProvider>(
      context,
      listen: false,
    );
    final merchantsProvider = Provider.of<MerchantsProvider>(
      context,
      listen: false,
    );
    final tagsProvider = Provider.of<TagsProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null || !mounted) return;

    try {
      await Future.wait([
        categoriesProvider.fetchCategories(accessToken: accessToken),
        merchantsProvider.fetchMerchants(accessToken: accessToken),
        tagsProvider.fetchTags(accessToken: accessToken),
      ]);
    } catch (_) {
      // Providers expose their own error state; avoid an uncaught async error.
    }
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate() || widget.transaction.id == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final transactionsProvider = Provider.of<TransactionsProvider>(
      context,
      listen: false,
    );
    final accessToken = await authProvider.getValidAccessToken();

    if (accessToken == null) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.transactionEditSessionExpired),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _isSaving = false;
      });
      return;
    }

    // Empty notes intentionally clear the server-side note.
    final notesText = _notesController.text.trim();

    final success = await transactionsProvider.updateTransaction(
      accessToken: accessToken,
      transaction: widget.transaction,
      name: _nameController.text.trim(),
      notes: notesText,
      categoryId: _selectedCategoryId,
      merchantId: _selectedMerchantId,
      tagIds: _selectedTagIds.toList(),
    );

    if (!mounted) return;

    setState(() {
      _isSaving = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? l.transactionEditUpdated
              : transactionsProvider.error ?? l.transactionEditUpdateFailed,
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );

    if (success) {
      Navigator.pop(context, true);
    }
  }

  String? _validateName(String? value) {
    final l = AppLocalizations.of(context);
    if (value == null || value.trim().isEmpty) {
      return l.transactionEditNameRequired;
    }

    if (value.trim().length > _maxNameLength) {
      return l.transactionEditNameMaxLength(_maxNameLength);
    }

    if (_containsControlCharacter(value)) {
      return l.transactionEditNameInvalidChars;
    }

    return null;
  }

  String? _validateNotes(String? value) {
    final l = AppLocalizations.of(context);
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    if (value.trim().length > _maxNotesLength) {
      return l.transactionEditNotesMaxLength(_maxNotesLength);
    }

    if (_containsControlCharacter(value, allowWhitespace: true)) {
      return l.transactionEditNotesInvalidChars;
    }

    return null;
  }

  bool _containsControlCharacter(
    String value, {
    bool allowWhitespace = false,
  }) {
    for (final codeUnit in value.codeUnits) {
      if (codeUnit == 127) return true;
      if (codeUnit < 32) {
        final allowedWhitespace = allowWhitespace &&
            (codeUnit == 9 || codeUnit == 10 || codeUnit == 13);
        if (!allowedWhitespace) return true;
      }
    }

    return false;
  }

  List<DropdownMenuItem<String?>> _categoryItems(
    List<models.Category> categories,
  ) {
    final l = AppLocalizations.of(context);
    final items = <DropdownMenuItem<String?>>[];
    if (_selectedCategoryId == null) {
      items.add(
        DropdownMenuItem<String?>(
          value: null,
          child: Text(l.transactionEditNoCategory),
        ),
      );
    }

    final hasCurrent = _selectedCategoryId == null ||
        categories.any((category) => category.id == _selectedCategoryId);
    if (!hasCurrent) {
      items.add(
        DropdownMenuItem<String?>(
          value: _selectedCategoryId,
          child: Text(widget.transaction.categoryName ?? l.transactionEditCurrentCategory),
        ),
      );
    }

    items.addAll(
      categories.map((category) {
        return DropdownMenuItem<String?>(
          value: category.id,
          child: Text(category.displayName),
        );
      }),
    );

    return items;
  }

  List<DropdownMenuItem<String?>> _merchantItems(List<Merchant> merchants) {
    final l = AppLocalizations.of(context);
    final items = <DropdownMenuItem<String?>>[];
    if (_selectedMerchantId == null) {
      items.add(
        DropdownMenuItem<String?>(
          value: null,
          child: Text(l.transactionEditNoMerchant),
        ),
      );
    }

    final hasCurrent = _selectedMerchantId == null ||
        merchants.any((merchant) => merchant.id == _selectedMerchantId);
    if (!hasCurrent) {
      items.add(
        DropdownMenuItem<String?>(
          value: _selectedMerchantId,
          child: Text(widget.transaction.merchantName ?? l.transactionEditCurrentMerchant),
        ),
      );
    }

    items.addAll(
      merchants.map((merchant) {
        return DropdownMenuItem<String?>(
          value: merchant.id,
          child: Text(merchant.name),
        );
      }),
    );

    return items;
  }

  Widget _buildTags(List<TransactionTag> tags, {required bool enabled}) {
    final l = AppLocalizations.of(context);
    if (tags.isEmpty && _selectedTagIds.isEmpty) {
      return Text(l.transactionEditNoTags);
    }

    final tagById = {for (final tag in tags) tag.id: tag};
    final combinedTags = [...tags];
    for (final selectedId in _selectedTagIds) {
      if (!tagById.containsKey(selectedId)) {
        final nameIndex = widget.transaction.tagIds.indexOf(selectedId);
        final fallbackName =
            nameIndex >= 0 && nameIndex < widget.transaction.tagNames.length
                ? widget.transaction.tagNames[nameIndex]
                : '';
        combinedTags.add(
          TransactionTag(
            id: selectedId,
            name: fallbackName.isNotEmpty ? fallbackName : l.transactionEditUnknownTag,
          ),
        );
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: combinedTags.map((tag) {
        final selected = _selectedTagIds.contains(tag.id);
        return FilterChip(
          label: Text(tag.name),
          selected: selected,
          onSelected: enabled
              ? (value) {
                  setState(() {
                    if (value) {
                      _selectedTagIds.add(tag.id);
                    } else {
                      _selectedTagIds.remove(tag.id);
                    }
                  });
                }
              : null,
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canEdit = widget.transaction.id != null &&
        widget.transaction.syncStatus == SyncStatus.synced;

    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.transactionEditTitle)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!canEdit) ...[
              Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l.transactionEditSyncedOnly,
                    style: TextStyle(color: colorScheme.onErrorContainer),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextFormField(
              controller: _nameController,
              enabled: canEdit && !_isSaving,
              validator: _validateName,
              maxLength: _maxNameLength,
              decoration: InputDecoration(
                labelText: l.transactionEditNameLabel,
                prefixIcon: const Icon(Icons.label),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesController,
              enabled: canEdit && !_isSaving,
              validator: _validateNotes,
              maxLength: _maxNotesLength,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l.transactionEditNotesLabel,
                prefixIcon: const Icon(Icons.notes),
              ),
            ),
            const SizedBox(height: 16),
            Consumer<CategoriesProvider>(
              builder: (context, categoriesProvider, _) {
                return DropdownButtonFormField<String?>(
                  value: _selectedCategoryId,
                  decoration: InputDecoration(
                    labelText: l.transactionEditCategoryLabel,
                    prefixIcon: const Icon(Icons.category),
                    helperText: l.transactionEditCategoryHelper,
                  ),
                  isExpanded: true,
                  items: _categoryItems(categoriesProvider.categories),
                  onChanged: canEdit && !_isSaving
                      ? (value) => setState(() => _selectedCategoryId = value)
                      : null,
                );
              },
            ),
            const SizedBox(height: 16),
            Consumer<MerchantsProvider>(
              builder: (context, merchantsProvider, _) {
                return DropdownButtonFormField<String?>(
                  value: _selectedMerchantId,
                  decoration: InputDecoration(
                    labelText: l.transactionEditMerchantLabel,
                    prefixIcon: const Icon(Icons.storefront),
                    helperText: l.transactionEditMerchantHelper,
                  ),
                  isExpanded: true,
                  items: _merchantItems(merchantsProvider.merchants),
                  onChanged: canEdit && !_isSaving
                      ? (value) => setState(() => _selectedMerchantId = value)
                      : null,
                );
              },
            ),
            const SizedBox(height: 24),
            Text(l.transactionEditTagsLabel, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Consumer<TagsProvider>(
              builder: (context, tagsProvider, _) =>
                  _buildTags(tagsProvider.tags, enabled: canEdit && !_isSaving),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: canEdit && !_isSaving ? _save : null,
              icon: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_isSaving ? l.transactionEditSaving : l.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}
