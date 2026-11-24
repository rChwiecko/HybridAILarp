import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meet_halfway/app.dart';
import 'package:meet_halfway/domain.dart';
import 'package:meet_halfway/firebase_service.dart';
import 'package:meet_halfway/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordingCloud extends FirebaseService {
  RecordingCloud() : super({});
  int extractions = 0;
  @override
  Future<(PreferenceCard, AIReceipt)> extractNote(
    String note,
    PreferenceCard base,
    Experience data,
  ) async {
    extractions++;
    return (base, AIReceipt('Preference draft', 'test model', 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MeetStore store;
  late RecordingCloud cloud;
  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final name in ['Regular', 'Medium', 'SemiBold']) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            File('assets/fonts/Inter-$name.ttf').readAsBytesSync(),
          ),
        ),
      );
    }
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    // Plugins with no test implementation: no incoming links, always online.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.app_links/messages'),
      (_) async => null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('com.llfbandit.app_links/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cloud = RecordingCloud();
    final data = Experience.fromJson(
      jsonDecode(File('../shared/experience.json').readAsStringSync()) as Json,
    );
    store = MeetStore(data, await SharedPreferences.getInstance(), cloud);
  });
  tearDown(() {
    store.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await tester.pumpWidget(MeetHalfwayApp(store: store));
    await tester.runAsync(() async {
      final context = tester.element(find.byType(MeetShell));
      for (final photo in store.data.catalog.map((a) => a.photo).toSet()) {
        await precacheImage(
          AssetImage('assets/activities/$photo.jpg'),
          context,
        );
      }
    });
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'shared phone UI matches the same visual baseline on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await open(tester, const Size(390, 844));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MeetShell),
          matchesGoldenFile('goldens/discover_phone.png'),
        );
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  testWidgets('desktop dashboard fits and has a visual baseline', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MeetShell),
      matchesGoldenFile('goldens/discover_desktop.png'),
    );
  });
  testWidgets('small phone and enlarged text retain usable navigation', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, const Size(320, 640));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('nav-plans')));
    await tester.pumpAndSettle();
    expect(find.text('Your plans, coming together.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('composer creates a local plan using the entered title', (
    tester,
  ) async {
    await open(tester, const Size(390, 844));
    await tester.enterText(
      find.byKey(const Key('plan-composer')),
      'A creative afternoon',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('plan-title')))
          .controller!
          .text,
      'A creative afternoon',
    );
    await tester.enterText(find.byKey(const Key('your-name')), 'Sam');
    await tester.ensureVisible(find.byKey(const Key('create-plan')));
    await tester.tap(find.byKey(const Key('create-plan')));
    await tester.pumpAndSettle();
    expect(store.room?.title, 'A creative afternoon');
    expect(store.room?.local, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'cloud note extraction requires consent and does not persist raw text',
    (tester) async {
      await open(tester, const Size(390, 844));
      await tester.tap(find.byKey(const Key('nav-preferences')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('preference-note')),
        'PRIVATE_CANARY_918273',
      );
      await tester.ensureVisible(find.text('Draft with cloud AI'));
      await tester.tap(find.text('Draft with cloud AI'));
      await tester.pumpAndSettle();
      expect(cloud.extractions, 0);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(cloud.extractions, 0);
      await tester.tap(find.text('Draft with cloud AI'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send and draft'));
      await tester.pumpAndSettle();
      expect(cloud.extractions, 1);
      for (final key in store.preferences.getKeys()) {
        expect(
          store.preferences.get(key).toString(),
          isNot(contains('PRIVATE_CANARY_918273')),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'sample room supports proposal, three-person voting and confirmation',
    (tester) async {
      store.localRooms[0] = PlanRoom(
        id: 'sample-toronto',
        title: 'Saturday, sorted.',
        date: '2026-11-21',
        ownerId: 'alex',
        members: store.data.samplePeople
            .map((p) => Person.fromJson(p.toJson()))
            .toList(),
      );
      await open(tester, const Size(390, 844));
      await tester.tap(find.byKey(const Key('explore-sample')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MeetShell),
        matchesGoldenFile('goldens/room_phone.png'),
      );
      Future<void> tapKey(String key) async {
        final target = find.byKey(Key(key));
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tapKey('details-${store.ranked.first.candidate.id}');
      await tapKey('propose-plan');
      expect(store.room!.status, 'voting');
      await tapKey('vote-yes');
      await tapKey('person-maya');
      await tapKey('vote-maybe');
      await tapKey('person-alex');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('confirm-plan')))
            .onPressed,
        isNull,
      );
      await tapKey('person-maya');
      await tapKey('vote-yes');
      await tapKey('person-jordan');
      await tapKey('vote-yes');
      await tapKey('person-alex');
      await tapKey('confirm-plan');
      expect(store.room!.status, 'confirmed');
      expect(find.text('Add to calendar'), findsOneWidget);
      expect(find.text('Share the plan'), findsOneWidget);
      await tapKey('details-${store.ranked.first.candidate.id}');
      expect(find.byKey(const Key('propose-plan')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('system Back leaves a plan before leaving the app', (
    tester,
  ) async {
    await open(tester, const Size(390, 844));
    await tester.tap(find.byKey(const Key('explore-sample')));
    await tester.pumpAndSettle();
    expect(store.room, isNotNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(store.room, isNull);
    expect(store.tab, 'plans');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(store.tab, 'discover');
    expect(tester.takeException(), isNull);
  });
}
