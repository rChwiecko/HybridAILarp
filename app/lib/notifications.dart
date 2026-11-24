import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_service.dart';

class NotificationService extends ChangeNotifier {
  NotificationService(this.cloud, this.preferences);
  final FirebaseService cloud;
  final SharedPreferences preferences;
  bool enabled = false;
  String? message;
  StreamSubscription<String>? _tokens;
  StreamSubscription<RemoteMessage>? _messages, _opened;
  String? _deviceId;
  void Function(String roomId)? onOpenRoom;

  Future<void> enable() async {
    await cloud.connect();
    if (cloud.config['pushEnabled'] != true) {
      throw StateError(
        'Push delivery is not enabled for this build yet. Your plan activity is available in Updates.',
      );
    }
    final vapid = cloud.config['webPushVapidKey'] as String?;
    if (kIsWeb && (vapid == null || vapid.isEmpty)) {
      throw StateError(
        'Web push needs a web push certificate. Updates are still available in the app.',
      );
    }
    final messaging = FirebaseMessaging.instance;
    final permission = await messaging.requestPermission();
    if (permission.authorizationStatus == AuthorizationStatus.denied ||
        permission.authorizationStatus == AuthorizationStatus.notDetermined) {
      throw StateError(
        'Notifications are disabled in your device or browser settings.',
      );
    }
    _deviceId = preferences.getString('meet.push.device') ?? randomId(12);
    await preferences.setString('meet.push.device', _deviceId!);
    await _tokens?.cancel();
    final registered = Completer<String>();
    _tokens = messaging.onRegistered.listen(
      (fid) {
        if (!registered.isCompleted) registered.complete(fid);
        unawaited(
          _saveToken(fid).catchError((Object _) {
            message = 'Notification registration could not be saved. Try enabling notifications again.';
            notifyListeners();
          }),
        );
      },
      onError: (Object error) {
        if (!registered.isCompleted) registered.completeError(error);
      },
    );
    await messaging
        .register(
          vapidKey: vapid,
          serviceWorkerScriptPath: kIsWeb ? 'firebase-messaging-sw.js' : null,
        )
        .timeout(const Duration(seconds: 25));
    final fid = await registered.future.timeout(const Duration(seconds: 25));
    await _saveToken(fid);
    await _messages?.cancel();
    _messages = FirebaseMessaging.onMessage.listen((event) {
      message = event.notification?.body ?? 'One of your plans has an update.';
      notifyListeners();
    });
    await _opened?.cancel();
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(_open);
    final initial = await messaging.getInitialMessage();
    if (initial != null) _open(initial);
    await preferences.setBool('meet.push.${cloud.uid}', true);
    enabled = true;
    notifyListeners();
  }

  void _open(RemoteMessage event) {
    final id = event.data['roomId'];
    if (id != null) onOpenRoom?.call(id);
  }

  Future<void> restore() async {
    if (cloud.connected &&
        preferences.getBool('meet.push.${cloud.uid}') == true) {
      try {
        await enable();
      } catch (_) {
        /* Updates remain available without push. */
      }
    }
  }

  Future<void> _saveToken(String fid) async {
    if (!cloud.connected || _deviceId == null) return;
    await cloud.db.doc('users/${cloud.uid}/devices/$_deviceId').set({
      'fid': fid,
      // The rules accept 'android', 'ios' and 'web'; the enum name is 'iOS'.
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> disable() async {
    await _tokens?.cancel();
    await _messages?.cancel();
    await _opened?.cancel();
    _tokens = null;
    _messages = null;
    _opened = null;
    _deviceId ??= preferences.getString('meet.push.device');
    if (cloud.connected && _deviceId != null) {
      await cloud.db.doc('users/${cloud.uid}/devices/$_deviceId').delete();
      await preferences.remove('meet.push.${cloud.uid}');
      if (enabled) await FirebaseMessaging.instance.unregister();
    }
    enabled = false;
    message = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _tokens?.cancel();
    _messages?.cancel();
    _opened?.cancel();
    super.dispose();
  }
}
