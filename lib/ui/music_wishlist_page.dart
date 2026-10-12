import 'package:flutter/material.dart';

import '../models/wish_item.dart';
import '../services/wishlist_store.dart';
import '../utils/wish_priority.dart';
import 'subpage_app_bar.dart';
import 'tag_picker_field.dart';

/// The Wishlist: ideas for the app, each a [WishItem] in [WishlistStore].
/// Each row is just a checkbox (mark done right from the list) and a title;
/// tapping the title opens every other field — priority, tags, description
/// — in one editor.
class MusicWishlistPage extends StatefulWidget {
  const MusicWishlistPage({super.key});

  @override
  State<MusicWishlistPage> createState() => _MusicWishlistPageState();
}

class _MusicWishlistPageState extends State<MusicWishlistPage> {
  final WishlistStore _store = WishlistStore.instance;

  /// Every record of the store; the page shows and mutates only the isWish
  /// ones but always persists the whole list.
  List<WishItem> _tasks = <WishItem>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tasks = await _store.load();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _store.save(_tasks);
  }

  /// Wishlist items: open items before done ones, then by priority,
  /// otherwise keeping list order.
  List<WishItem> _wishes() {
    final wishes = _tasks.where((t) => t.isWish).toList();
    final order = <String, int>{
      for (var i = 0; i < wishes.length; i++) wishes[i].uid: i,
    };
    wishes.sort((a, b) {
      if (a.isDone != b.isDone) return a.isDone ? 1 : -1;
      final byPriority = wishPriorityRank(b) - wishPriorityRank(a);
      if (byPriority != 0) return byPriority;
      return order[a.uid]!.compareTo(order[b.uid]!);
    });
    return wishes;
  }

  /// Every tag on a Wishlist item except the priority ones (those have
  /// their own chips in the editor).
  List<String> _knownTags() {
    final seen = <String>{};
    return [
      for (final item in _tasks)
        if (item.isWish)
          for (final tag in splitTags(item.label))
            if (!wishPriorityLabels.contains(tag.toLowerCase()) &&
                seen.add(tag.toLowerCase()))
              tag,
    ];
  }

  void _toggleDone(WishItem item) {
    setState(() {
      item.isDone = !item.isDone;
      item.completedAt = item.isDone ? DateTime.now() : null;
    });
    _save();
  }

  Future<void> _openItem([WishItem? item]) async {
    final result = await Navigator.of(context).push<_MusicWishItemResult>(
      MaterialPageRoute(
          builder: (_) =>
              _MusicWishItemPage(item: item, knownTags: _knownTags())),
    );
    if (result == null) return;
    setState(() {
      if (result.deleted) {
        if (item != null) _tasks.remove(item);
      } else if (item == null) {
        _tasks.insert(
          0,
          WishItem(
            title: result.title,
            description: result.description,
            label: result.label,
            createdAt: DateTime.now(),
            isDone: result.isDone,
          ),
        );
      } else {
        item
          ..title = result.title
          ..description = result.description
          ..label = result.label
          ..isDone = result.isDone
          ..completedAt =
              result.isDone ? (item.completedAt ?? DateTime.now()) : null;
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final wishes = _wishes();
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: 'Wishlist'),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add wishlist item',
        onPressed: () => _openItem(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : wishes.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No wishlist items yet. Add ideas here; tap one to see '
                            'its description, priority and tags.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
                        itemCount: wishes.length,
                        itemBuilder: (context, index) {
                          final item = wishes[index];
                          return ListTile(
                            leading: Checkbox(
                              value: item.isDone,
                              onChanged: (_) => _toggleDone(item),
                            ),
                            title: Text(
                              item.title,
                              style: TextStyle(
                                decoration: item.isDone
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            onTap: () => _openItem(item),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _MusicWishItemResult {
  final String title;
  final String description;
  final String label;
  final bool isDone;
  final bool deleted;

  const _MusicWishItemResult({
    this.title = '',
    this.description = '',
    this.label = '',
    this.isDone = false,
    this.deleted = false,
  });
}

/// Full-page editor for one wishlist item — every field the list itself
/// hides: title, done, priority (`priority-low/medium/high` tags), tags and
/// description. Owns its own text
/// controllers so the page's exit transition never touches a disposed one.
class _MusicWishItemPage extends StatefulWidget {
  final WishItem? item;

  const _MusicWishItemPage({this.item, this.knownTags = const []});

  /// Tags used on the other items, offered by the tag picker.
  final List<String> knownTags;

  @override
  State<_MusicWishItemPage> createState() => _MusicWishItemPageState();
}

class _MusicWishItemPageState extends State<_MusicWishItemPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late String _label;
  late bool _isDone;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.item?.title ?? '');
    _descriptionController =
        TextEditingController(text: widget.item?.description ?? '');
    _label = widget.item?.label ?? '';
    _isDone = widget.item?.isDone ?? false;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  List<String> _labelsFromText(String text) => text
      .split(RegExp(r'[,\s]+'))
      .map((label) => label.trim())
      .where((label) => label.isNotEmpty)
      .toList();

  void _setPriority(String priorityLabel) {
    final labels = _labelsFromText(_label)
        .where((label) => !wishPriorityLabels.contains(label.toLowerCase()))
        .toList();
    labels.insert(0, priorityLabel);
    setState(() => _label = labels.join(', '));
  }

  int get _priorityRank {
    final labels = _labelsFromText(_label).map((l) => l.toLowerCase()).toSet();
    for (var i = wishPriorityLabels.length - 1; i >= 0; i--) {
      if (labels.contains(wishPriorityLabels[i])) return i + 1;
    }
    return 0;
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(_MusicWishItemResult(
      title: title,
      description: _descriptionController.text.trim(),
      label: _label.trim(),
      isDone: _isDone,
    ));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete wishlist item?'),
        content: Text('"${widget.item!.title}" will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(const _MusicWishItemResult(deleted: true));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.item == null;
    return Scaffold(
      appBar: buildSubpageAppBar(
        context,
        title: isNew ? 'Add wishlist item' : 'Edit wishlist item',
        actions: [
          if (!isNew)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              autofocus: isNew,
              decoration: const InputDecoration(labelText: 'Title'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Done'),
              value: _isDone,
              onChanged: (v) => setState(() => _isDone = v),
            ),
            const SizedBox(height: 4),
            Text('Priority', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < wishPriorityLabels.length; i++)
                  ChoiceChip(
                    label: Text(
                        wishPriorityLabels[i].replaceFirst('priority-', '')),
                    selected: _priorityRank == i + 1,
                    onSelected: (_) => _setPriority(wishPriorityLabels[i]),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TagPickerField(
              value: _label,
              knownTags: widget.knownTags,
              onChanged: (v) => setState(() => _label = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 5,
            ),
          ],
        ),
      ),
    );
  }
}
