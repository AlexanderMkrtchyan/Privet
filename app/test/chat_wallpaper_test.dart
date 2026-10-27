import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/chat_wallpaper.dart';
import 'package:privet/widgets/chat_wallpaper_picker.dart';

void main() {
  test('catalog has doodle themes only', () {
    expect(ChatWallpaperCatalog.doodles, hasLength(6));
    expect(ChatWallpaperCatalog.byId('doodle:math').label, 'Math');
    expect(ChatWallpaperCatalog.byId('doodle:physics').kind,
        ChatWallpaperKind.doodle);
    expect(ChatWallpaperCatalog.byId('pattern:formulas').id,
        ChatWallpaperCatalog.noneId);
    expect(ChatWallpaperCatalog.byId('photo:01').id, ChatWallpaperCatalog.noneId);
    expect(ChatWallpaperCatalog.byId('missing').id, ChatWallpaperCatalog.noneId);
    expect(
      ChatWallpaperCatalog.byId('doodle:math').assetFor(Brightness.dark),
      'assets/wallpapers/doodles/math-dark.jpg',
    );
    expect(
      ChatWallpaperCatalog.byId('doodle:math').assetFor(Brightness.light),
      'assets/wallpapers/doodles/math-light.jpg',
    );
    expect(
      ChatWallpaperCatalog.byId('doodle:math')
          .assetFor(Brightness.dark, ChatWallpaperPack.fhd),
      'assets/wallpapers/doodles/fhd/math-dark.jpg',
    );
    expect(
      ChatWallpaperCatalog.byId('doodle:math')
          .assetFor(Brightness.light, ChatWallpaperPack.qhd),
      'assets/wallpapers/doodles/2k/math-light.jpg',
    );
  });

  test('Linux 1080p window picks FHD, QHD picks 2K', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(
      chatWallpaperPackFor(const Size(1920, 1080)),
      ChatWallpaperPack.fhd,
    );
    expect(
      chatWallpaperPackFor(const Size(2560, 1440)),
      ChatWallpaperPack.qhd,
    );
  });

  test('phone keeps the portrait pack', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(
      chatWallpaperPackFor(const Size(1440, 3200)),
      ChatWallpaperPack.mobile,
    );
  });

  testWidgets('picker selects a doodle theme', (tester) async {
    var selected = ChatWallpaperCatalog.noneId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatWallpaperPicker(
              selectedId: selected,
              onSelect: (id) => selected = id,
              onUpload: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Math'));
    await tester.pump();
    expect(selected, 'doodle:math');
  });

  testWidgets('picker has no Telegram photo or pattern tiles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatWallpaperPicker(
              selectedId: ChatWallpaperCatalog.noneId,
              onSelect: (_) {},
              onUpload: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Formulas'), findsNothing);
    expect(find.byTooltip('Nebula'), findsNothing);
    expect(find.byTooltip('Math'), findsOneWidget);
  });

  testWidgets('picker upload tile calls onUpload', (tester) async {
    var uploaded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatWallpaperPicker(
              selectedId: ChatWallpaperCatalog.noneId,
              onSelect: (_) {},
              onUpload: () => uploaded = true,
            ),
          ),
        ),
      ),
    );

    final upload = find.byTooltip('Upload');
    await tester.ensureVisible(upload);
    await tester.pump();
    await tester.tap(upload);
    await tester.pump();
    expect(uploaded, isTrue);
  });
}

