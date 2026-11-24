import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'domain.dart';
import 'firebase_plans.dart';
import 'firebase_service.dart';
import 'account_merge.dart';

extension FirebaseAccounts on FirebaseService {
  User? get account => connected ? auth.currentUser : null;
  bool get hasAccount => account != null && !account!.isAnonymous;

  /// Linking preserves the guest UID and every room membership.
  Future<void> registerAccount(String email, String password) async {
    await connect();
    final credential = EmailAuthProvider.credential(
      email: email.trim(),
      password: password,
    );
    if (auth.currentUser!.isAnonymous) {
      await auth.currentUser!.linkWithCredential(credential);
    } else {
      throw StateError('You are already signed in.');
    }
    await auth.currentUser!.sendEmailVerification();
  }

  Future<void> signInAccount(String email, String password) async {
    await connect();
    if (auth.currentUser!.isAnonymous) {
      final guestRooms = await db
          .collection('rooms')
          .where('memberIds', arrayContains: uid)
          .limit(1)
          .get();
      if (guestRooms.docs.isNotEmpty) {
        await mergeGuestInto(email, password);
        return;
      }
    }
    await auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> resetPassword(String email) async {
    await connect();
    await auth.sendPasswordResetEmail(email: email.trim());
  }

  Future<void> signOutAccount() async {
    await connect();
    await auth.signOut();
    await auth.signInAnonymously();
  }

  Future<Json?> loadProfile() async {
    await connect();
    return (await db.doc('users/$uid').get()).data();
  }

  Future<void> saveProfile(String name, PreferenceCard card) async {
    await connect();
    await db.doc('users/$uid').set({
      'name': name,
      'card': card.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<Json> exportCloudData() async {
    await connect();
    final result = <String, dynamic>{
      'profile': await loadProfile(),
      'rooms': <Json>[],
    };
    for (final path in [
      'history',
      'historyHidden',
      'planInvites',
      'inbox',
      'devices',
    ]) {
      result[path] = (await db.collection('users/$uid/$path').get()).docs
          .map((d) => <String, dynamic>{'id': d.id, ...d.data()})
          .toList();
    }
    result['friendships'] =
        (await db
                .collection('friendships')
                .where('members', arrayContains: uid)
                .get())
            .docs
            .map((d) => <String, dynamic>{'id': d.id, ...d.data()})
            .toList();
    result['friendLinks'] =
        (await db
                .collection('friendInvites')
                .where('ownerId', isEqualTo: uid)
                .get())
            .docs
            .map((d) => <String, dynamic>{'id': d.id, ...d.data()})
            .toList();
    result['sentPlanInvites'] =
        (await db
                .collectionGroup('planInvites')
                .where('fromId', isEqualTo: uid)
                .get())
            .docs
            .map(
              (d) => <String, dynamic>{'path': d.reference.path, ...d.data()},
            )
            .toList();
    final headers = await db
        .collection('rooms')
        .where('memberIds', arrayContains: uid)
        .get();
    for (final header in headers.docs) {
      final room = <String, dynamic>{'id': header.id, ...header.data()};
      for (final path in ['members', 'options', 'votes', 'routes', 'events']) {
        room[path] = (await header.reference.collection(path).get()).docs
            .map((d) => {'id': d.id, ...d.data()})
            .toList();
      }
      (result['rooms'] as List).add(room);
    }
    return result;
  }

  Future<void> deleteAccount(String password) async {
    await connect();
    final user = auth.currentUser!;
    if (!user.isAnonymous && user.email != null) {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: user.email!, password: password),
      );
    }
    // Leave every live plan, as the Leave action would. Hosted plans pass to
    // the earliest other member; a plan nobody else joined is deleted.
    for (final room in await rooms()) {
      final header = (await db.doc('rooms/${room.id}').get()).data()!;
      final others = List<String>.from(header['memberIds'] as List)
        ..remove(uid);
      if (room.ownerId == uid && others.isEmpty) {
        await deletePlan(room);
        continue;
      }
      if (room.ownerId == uid) await transferHost(room, others.first);
      await removeMember(room, uid);
    }
    // Remove both sides of social relationships and pending invitations before
    // the credentials that authorize this cleanup are deleted.
    for (final query in <Query<Map<String, dynamic>>>[
      db.collection('friendships').where('members', arrayContains: uid),
      db.collection('friendInvites').where('ownerId', isEqualTo: uid),
      db.collectionGroup('planInvites').where('fromId', isEqualTo: uid),
      db.collection('accountMigrations').where('guestId', isEqualTo: uid),
      db.collection('accountMigrations').where('targetId', isEqualTo: uid),
    ]) {
      await _purgeQuery(query);
    }
    for (final collection in [
      'devices',
      'inbox',
      'delivery',
      'history',
      'historyHidden',
      'planInvites',
    ]) {
      await _purgeQuery(db.collection('users/$uid/$collection'));
    }
    await db.doc('users/$uid').delete();
    await user.delete();
    await auth.signInAnonymously();
  }

  Future<void> _purgeQuery(Query<Map<String, dynamic>> query) async {
    while (true) {
      final docs = await query.limit(100).get();
      if (docs.docs.isEmpty) break;
      final batch = db.batch();
      for (final d in docs.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
  }
}
