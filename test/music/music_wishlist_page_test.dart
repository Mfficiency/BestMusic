import 'dart:io';

import 'package:best_music/models/wish_item.dart';
import 'package:best_music/services/wishlist_store.dart';
import 'package:best_music/ui/music_wishlist_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The Wishlist: a plain list over the [WishItem] records of
/// [WishlistStore] (`tasks.json`); each row is just a checkbox and a title,
/// with no other chrome.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  /// Pumps rounds of real-event-loop delay + frame pumps until [finder]
  /// finds something, or [rounds] is exhausted — the pattern real `dart:io`
  /// work inside a widget needs under `testWidgets`'s fake-async zone (see
  /// CLAUDE.md).
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
      {int rounds = 300}) async {
    for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    await tester.pump();
  }

  /// A save started by a tap handler is awaited before the write actually
  /// lands on disk; a fixed number of runAsync rounds lets it finish before
  /// the test reads storage back.
  Future<void> settleWrites(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  Future<void> pumpWishlist(
    WidgetTester tester, {
    required List<WishItem> tasks,
    required Finder marker,
  }) async {
    await tester.runAsync(() => WishlistStore.instance.save(tasks));
    await tester.pumpWidget(const MaterialApp(home: MusicWishlistPage()));
    await pumpUntilFound(tester, marker);
  }

  testWidgets(
      'shows only wish-flagged items, as a checkbox and title with no other chrome',
      (tester) async {
    final wish = WishItem(
      title: 'Learn to sail',
      label: 'priority-medium',
      createdAt: DateTime.now(),
    );
    final regularTask =
        WishItem(title: 'Buy milk', isWish: false, createdAt: DateTime.now());
    await pumpWishlist(tester,
        tasks: [wish, regularTask], marker: find.text('Learn to sail'));

    expect(find.text('Learn to sail'), findsOneWidget);
    expect(find.text('Buy milk'), findsNothing);

    final tile = tester.widget<ListTile>(find.byType(ListTile).first);
    expect(tile.leading, isA<Checkbox>());
    expect(tile.trailing, isNull);
    final checkbox = tile.leading as Checkbox;
    expect(checkbox.value, isFalse);
  });

  testWidgets(
      'tapping the checkbox marks an item done and persists it, without '
      'opening the editor', (tester) async {
    final wish = WishItem(
      title: 'Mark me done',
      createdAt: DateTime.now(),
    );
    await pumpWishlist(tester,
        tasks: [wish], marker: find.text('Mark me done'));

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await settleWrites(tester);

    expect(find.text('Edit wishlist item'), findsNothing);
    final tile = tester.widget<ListTile>(find.byType(ListTile).first);
    final checkbox = tile.leading as Checkbox;
    expect(checkbox.value, isTrue);
    expect((tile.title as Text).style?.decoration, TextDecoration.lineThrough);

    final saved = await tester.runAsync(() => WishlistStore.instance.load());
    expect(saved!.single.isDone, isTrue);
    expect(saved.single.completedAt, isNotNull);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await settleWrites(tester);
    final unsaved =
        await tester.runAsync(() => WishlistStore.instance.load());
    expect(unsaved!.single.isDone, isFalse);
    expect(unsaved.single.completedAt, isNull);
  });

  testWidgets('empty state shown when there are no wishlist items',
      (tester) async {
    await pumpWishlist(
      tester,
      tasks: const [],
      marker: find.textContaining('No wishlist items yet'),
    );

    expect(find.textContaining('No wishlist items yet'), findsOneWidget);
  });

  testWidgets('tapping an item opens its description, priority and tags',
      (tester) async {
    final wish = WishItem(
      title: 'New headphones',
      description: 'Over-ear, noise cancelling',
      label: 'priority-high, gift-idea',
      createdAt: DateTime.now(),
    );
    await pumpWishlist(tester,
        tasks: [wish], marker: find.text('New headphones'));

    await tester.tap(find.text('New headphones'));
    await tester.pumpAndSettle();

    expect(find.text('Edit wishlist item'), findsOneWidget);
    expect(find.text('Over-ear, noise cancelling'), findsOneWidget);
    expect(find.text('gift-idea'), findsOneWidget);
    final highChip =
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'high'));
    expect(highChip.selected, isTrue);
  });

  testWidgets('editing title and description saves back to storage',
      (tester) async {
    final wish = WishItem(
      title: 'Old title',
      createdAt: DateTime.now(),
    );
    await pumpWishlist(tester, tasks: [wish], marker: find.text('Old title'));

    await tester.tap(find.text('Old title'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'New title');
    await tester.enterText(
        find.widgetWithText(TextField, 'Description'), 'A new description');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    await settleWrites(tester);

    expect(find.text('New title'), findsOneWidget);

    final saved = await tester.runAsync(() => WishlistStore.instance.load());
    final savedWish = saved!.single;
    expect(savedWish.title, 'New title');
    expect(savedWish.description, 'A new description');
    expect(savedWish.isWish, isTrue);
  });

  testWidgets('adding a new item via the FAB creates a wish-flagged task',
      (tester) async {
    await pumpWishlist(
      tester,
      tasks: const [],
      marker: find.textContaining('No wishlist items yet'),
    );

    await tester.tap(find.byTooltip('Add wishlist item'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Title'), 'Concert tickets');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    await settleWrites(tester);

    expect(find.text('Concert tickets'), findsOneWidget);
    final saved = await tester.runAsync(() => WishlistStore.instance.load());
    expect(saved!.single.isWish, isTrue);
    expect(saved.single.title, 'Concert tickets');
  });

  testWidgets('deleting an item from the editor removes it from the list',
      (tester) async {
    final wish = WishItem(
      title: 'To be deleted',
      createdAt: DateTime.now(),
    );
    await pumpWishlist(tester,
        tasks: [wish], marker: find.text('To be deleted'));

    await tester.tap(find.text('To be deleted'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    await settleWrites(tester);

    expect(find.text('To be deleted'), findsNothing);
    expect(find.textContaining('No wishlist items yet'), findsOneWidget);

    final saved = await tester.runAsync(() => WishlistStore.instance.load());
    expect(saved, isEmpty);
  });

  testWidgets('the tag picker offers tags used on other items',
      (tester) async {
    await pumpWishlist(tester, tasks: [
      WishItem(title: 'First', label: 'gift-idea, priority-low'),
      WishItem(title: 'Second'),
    ], marker: find.text('Second'));

    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(CheckboxListTile, 'gift-idea'), findsOneWidget);
    // Priority has its own chips, so it isn't offered as a tag.
    expect(find.widgetWithText(CheckboxListTile, 'priority-low'), findsNothing);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'gift-idea'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    await settleWrites(tester);

    final saved = await tester.runAsync(() => WishlistStore.instance.load());
    expect(saved!.firstWhere((w) => w.title == 'Second').label, 'gift-idea');
  });
}
