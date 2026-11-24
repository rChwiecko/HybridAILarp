import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'actions.dart';
import 'design.dart';
import 'dialogs.dart';
import 'discovery_service.dart';
import 'domain.dart';
import 'firebase_accounts.dart';
import 'firebase_plans.dart';
import 'screens.dart' show PageBody;
import 'store.dart';
import 'social_screens.dart' show planInvitations;

Future<void> showRoutingConsent(
  BuildContext context,
  MeetStore store, {
  List<Activity>? itinerary,
}) async {
  if (!await confirmAction(
        context,
        'Use sourced travel times?',
        'Shared neighbourhood and venue coordinates, travel modes, access routing needs and plan times will go to Transitous. No names or notes are sent. Results replace travel estimates for ranking, expire after 15 minutes, and reopen the group decision. Unavailable trips stay excluded.',
        'Check and use routes',
      ) ||
      !context.mounted) {
    return;
  }
  await perform(
    context,
    store,
    () => store.refreshRoutedTravel(itinerary: itinerary),
    message: 'Sourced travel is now used for this plan.',
  );
}

Widget sourceCredits() => Wrap(
  spacing: 8,
  runSpacing: 4,
  children: [
    TextButton(
      onPressed: () =>
          launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
      child: const Text('© OpenStreetMap contributors'),
    ),
    TextButton(
      onPressed: () => launchUrl(Uri.parse('https://transitous.org/sources/')),
      child: const Text('Transitous routing sources'),
    ),
    TextButton(
      onPressed: () => launchUrl(Uri.parse(providerContact)),
      child: const Text('MeetHalfway source and contact'),
    ),
  ],
);

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String body,
  String label,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(label),
          ),
        ],
      ),
    ) ??
    false;

class LocalAIPanel extends StatefulWidget {
  const LocalAIPanel({super.key, required this.store});
  final MeetStore store;
  @override
  State<LocalAIPanel> createState() => _LocalAIPanelState();
}

class _LocalAIPanelState extends State<LocalAIPanel> {
  @override
  void initState() {
    super.initState();
    widget.store.localAI.initialize();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store.localAI,
    builder: (context, _) {
      final ai = widget.store.localAI;
      return GlassSurface(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'AI on this device',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 10),
            Text(
              ai.unavailableReason ??
                  '${ai.modelName} · ${ai.installed ? "Downloaded" : "Optional download"}',
            ),
            const SizedBox(height: 10),
            Text(
              ai.downloadDescription,
              style: const TextStyle(
                fontSize: 12,
                color: MH.secondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Inference stays on your device. Downloads contact the model host; notes are never included in download requests. Cloud AI always requires its own approval.',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            TextButton(
              onPressed: () => launchUrl(Uri.parse(ai.modelSource)),
              child: const Text('Model source and terms'),
            ),
            if (ai.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(ai.error!),
              ),
            if (ai.working) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: ai.progress > 0 && !ai.installed ? ai.progress : null,
              ),
              TextButton(
                onPressed: ai.cancel,
                child: const Text('Cancel local AI task'),
              ),
            ] else if (ai.unavailableReason == null) ...[
              const SizedBox(height: 14),
              if (!ai.installed)
                FilledButton.icon(
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () async {
                    final agreed = await confirmAction(
                      context,
                      'Download ${ai.modelName}?',
                      ai.downloadDescription,
                      'Download model',
                    );
                    if (!agreed || !context.mounted) return;
                    try {
                      await ai.download();
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(friendlyError(error))),
                        );
                      }
                    }
                  },
                  label: const Text('Download local AI'),
                )
              else
                OutlinedButton(
                  onPressed: () => perform(context, widget.store, ai.remove),
                  child: const Text('Remove downloaded model'),
                ),
            ],
          ],
        ),
      );
    },
  );
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.store});
  final MeetStore store;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController();
  bool register = true;
  @override
  void initState() {
    super.initState();
    name.text = widget.store.name;
  }

  @override
  void dispose() {
    email.dispose();
    password.clear();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> exportData() async {
    await perform(context, widget.store, () async {
      final cloud = widget.store.cloud.connected
          ? await widget.store.cloud.exportCloudData()
          : null;
      final data = {
        'localPlans': widget.store.localRooms.map((r) => r.toJson()).toList(),
        'preferences': widget.store.defaultCard!.toJson(),
        'localHistory': widget.store.history
            .where((entry) => entry['cloud'] != true)
            .toList(),
        'cloud': cloud,
      };
      final json = const JsonEncoder.withIndent('  ', _jsonValue).convert(data);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(json)),
              mimeType: 'application/json',
            ),
          ],
          fileNameOverrides: ['meethalfway-data.json'],
          sharePositionOrigin: const Rect.fromLTWH(20, 80, 200, 50),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store, cloud = store.cloud;
    return PageBody(
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle(
            'Your account, your choice.',
            subtitle: 'Keep your plans and preferences across devices.',
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => store.navigate('people'),
                icon: const Icon(Icons.people_outline),
                label: const Text('My people'),
              ),
              OutlinedButton.icon(
                onPressed: () => store.navigate('history'),
                icon: const Icon(Icons.history_rounded),
                label: const Text('History and private ratings'),
              ),
              TextButton(
                onPressed: () => store.navigate('privacy'),
                child: const Text('Privacy'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          GlassSurface(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  cloud.hasAccount
                      ? 'Signed in as ${cloud.account!.email}'
                      : 'You’re using this device as a guest.',
                ),
                const SizedBox(height: 14),
                sharedTextField(
                  controller: name,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: 'Your display name',
                  ),
                ),
                OutlinedButton(
                  onPressed: store.busy
                      ? null
                      : () => perform(
                          context,
                          store,
                          () => store.rename(name.text),
                        ),
                  child: const Text('Save name'),
                ),
                if (!cloud.hasAccount) ...[
                  const SizedBox(height: 18),
                  Text(
                    register
                        ? 'Create an account to keep your current guest identity and plans.'
                        : 'Sign in to recover an existing account. Any guest plans here will move to that account after the password is verified.',
                  ),
                  const SizedBox(height: 14),
                  sharedTextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  sharedTextField(
                    controller: password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: store.busy || !cloud.configured
                        ? null
                        : () async {
                            final secret = password.text;
                            final ok = await perform(
                              context,
                              store,
                              () => register
                                  ? store.register(email.text, secret)
                                  : store.signIn(email.text, secret),
                              message: register
                                  ? 'Account created. Check your email to verify it.'
                                  : 'Welcome back.',
                            );
                            password.clear();
                            if (ok && mounted) setState(() {});
                          },
                    child: Text(
                      register ? 'Create account and keep my plans' : 'Sign in',
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => register = !register),
                    child: Text(
                      register
                          ? 'I already have an account'
                          : 'Create a new account',
                    ),
                  ),
                  TextButton(
                    onPressed: store.busy
                        ? null
                        : () => perform(
                            context,
                            store,
                            () => cloud.resetPassword(email.text),
                            message: 'If an account exists, check your email for password reset instructions.',
                          ),
                    child: const Text('Reset password'),
                  ),
                ] else ...[
                  if (!cloud.account!.emailVerified)
                    TextButton(
                      onPressed: () => perform(
                        context,
                        store,
                        () => cloud.account!.sendEmailVerification(),
                        message: 'Check your email.',
                      ),
                      child: const Text('Resend verification email'),
                    ),
                  OutlinedButton(
                    onPressed: store.busy
                        ? null
                        : () => perform(context, store, store.signOut),
                    child: const Text('Sign out'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          LocalAIPanel(store: store),
          const SizedBox(height: 20),
          GlassSurface(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Plan notifications',
                  style: TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Updates are always available in the app. Optional push notifications use a generic message, without preference-card details.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: store.busy
                      ? null
                      : () => perform(
                          context,
                          store,
                          store.notifications.enabled
                              ? store.notifications.disable
                              : store.notifications.enable,
                        ),
                  child: Text(
                    store.notifications.enabled
                        ? 'Turn off push notifications'
                        : 'Enable push notifications',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: store.busy ? null : exportData,
            child: const Text('Export my planning data'),
          ),
          if (cloud.connected)
            TextButton(
              onPressed: store.busy
                  ? null
                  : () async {
                      final controller = TextEditingController();
                      final accepted = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Delete your account?'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'You will leave your live plans. Plans you host pass to another member, or are deleted if nobody else has joined. This permanently deletes your private cloud profile, notification registrations, and sign-in.',
                              ),
                              sharedTextField(
                                controller: controller,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Password (accounts only)',
                                ),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Delete account'),
                            ),
                          ],
                        ),
                      );
                      final secret = controller.text;
                      controller.clear();
                      controller.dispose();
                      if (accepted != true || !context.mounted) return;
                      await perform(context, store, () async {
                        await store.notifications.disable();
                        await cloud.deleteAccount(secret);
                        await store.signOut();
                      });
                    },
              child: const Text('Delete cloud account and profile'),
            ),
        ],
      ),
    );
  }
}

Object? _jsonValue(Object? value) => value is Timestamp
    ? value.toDate().toUtc().toIso8601String()
    : value.toString();

Future<void> showManagePlan(BuildContext context, MeetStore store) =>
    showDialog<void>(
      context: context,
      builder: (_) => ManagePlanDialog(store: store),
    );

class ManagePlanDialog extends StatefulWidget {
  const ManagePlanDialog({super.key, required this.store});
  final MeetStore store;
  @override
  State<ManagePlanDialog> createState() => _ManagePlanDialogState();
}

class _ManagePlanDialogState extends State<ManagePlanDialog> {
  late final title = TextEditingController(text: widget.store.room!.title);
  late final name = TextEditingController(
    text: widget.store.me?.name ?? widget.store.name,
  );
  late String date = widget.store.room!.date;
  @override
  void dispose() {
    title.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store, room = store.room;
      if (room == null) return const SizedBox.shrink();
      return PlanDialog(
        title: 'Manage your plan.',
        subtitle: 'Changes reopen the decision so everyone can agree again.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sharedTextField(
              controller: name,
              maxLength: 30,
              decoration: const InputDecoration(
                labelText: 'Your name in this plan',
              ),
            ),
            OutlinedButton(
              onPressed: store.busy
                  ? null
                  : () =>
                        perform(context, store, () => store.rename(name.text)),
              child: const Text('Update my name'),
            ),
            if (store.isHost) ...[
              const SizedBox(height: 20),
              sharedTextField(
                controller: title,
                maxLength: 70,
                decoration: const InputDecoration(labelText: 'Plan title'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(readableDate(date)),
                onPressed: () async {
                  final now = DateTime.now();
                  final chosen = await showDatePicker(
                    context: context,
                    initialDate: DateTime.parse(date).isBefore(now)
                        ? now
                        : DateTime.parse(date),
                    firstDate: DateTime(now.year, now.month, now.day),
                    lastDate: DateTime(2100),
                  );
                  if (chosen != null && mounted) {
                    setState(() => date = isoDate(chosen));
                  }
                },
              ),
              OutlinedButton(
                onPressed: store.busy
                    ? null
                    : () => perform(
                        context,
                        store,
                        () => store.editPlan(title.text, date),
                      ),
                child: const Text('Save plan details'),
              ),
              const SizedBox(height: 18),
              const Text('Activities', style: TextStyle(fontSize: 17)),
              if (room.options.isEmpty)
                const Text('This plan uses the sample catalogue.'),
              for (final option in room.options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(option['name'] as String),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: 'Edit activity',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: store.busy
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) => AddOptionDialog(
                                  store: store,
                                  seed: option,
                                  optionId: option['id'] as String,
                                ),
                              ),
                      ),
                      IconButton(
                        tooltip: 'Remove activity',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: store.busy
                            ? null
                            : () async {
                                if (await confirmAction(
                                      context,
                                      'Remove this activity?',
                                      'The group decision will reopen.',
                                      'Remove',
                                    ) &&
                                    context.mounted) {
                                  await perform(
                                    context,
                                    store,
                                    () => store.updateOption(
                                      option['id'] as String,
                                      null,
                                    ),
                                  );
                                }
                              },
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              const Text('People', style: TextStyle(fontSize: 17)),
              for (final person in room.members.where(
                (p) => p.id != room.ownerId,
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(person.name),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (!await confirmAction(
                            context,
                            action == 'host'
                                ? 'Transfer hosting?'
                                : 'Remove this person?',
                            action == 'host'
                                ? '${person.name} will control this plan.'
                                : 'They will lose access. Revoke old invitations below to prevent joining again.',
                            'Continue',
                          ) ||
                          !context.mounted) {
                        return;
                      }
                      await perform(
                        context,
                        store,
                        () => action == 'host'
                            ? store.transfer(person.id)
                            : store.removePerson(person.id),
                      );
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'host', child: Text('Make host')),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from plan'),
                      ),
                    ],
                  ),
                ),
              if (!room.local)
                OutlinedButton(
                  onPressed: store.busy
                      ? null
                      : () async {
                          if (!await confirmAction(
                                context,
                                'Revoke all old invitations?',
                                'Existing members keep access. Only the new link will admit people.',
                                'Revoke links',
                              ) ||
                              !context.mounted) {
                            return;
                          }
                          await perform(
                            context,
                            store,
                            () async {
                              await store.cloud.revokeInvitations(room);
                            },
                            message: 'Old invitations revoked. Share a new link when ready.',
                          );
                        },
                  child: const Text('Revoke old invitation links'),
                ),
              TextButton(
                onPressed: store.busy
                    ? null
                    : () async {
                        if (!await confirmAction(
                              context,
                              'Permanently delete this plan?',
                              'The plan, shared cards, votes, activities and invitations will be removed for everyone.',
                              'Delete plan',
                            ) ||
                            !context.mounted) {
                          return;
                        }
                        if (await perform(
                              context,
                              store,
                              store.deleteCurrentPlan,
                            ) &&
                            context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                child: const Text('Delete this plan'),
              ),
            ] else
              TextButton(
                onPressed: store.busy
                    ? null
                    : () async {
                        if (!await confirmAction(
                              context,
                              'Leave this plan?',
                              'Your shared card and vote will be removed. The group decision will reopen.',
                              'Leave',
                            ) ||
                            !context.mounted) {
                          return;
                        }
                        if (await perform(
                              context,
                              store,
                              () => store.removePerson(store.myId),
                            ) &&
                            context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                child: const Text('Leave this plan'),
              ),
          ],
        ),
      );
    },
  );
}

class UpdatesScreen extends StatelessWidget {
  const UpdatesScreen({super.key, required this.store});
  final MeetStore store;
  @override
  Widget build(BuildContext context) => PageBody(
    maxWidth: 850,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle(
          'Your people, catching up.',
          subtitle: 'Recent activity in your live plans.',
        ),
        const SizedBox(height: 24),
        planInvitations(context, store),
        if (store.activityFeed.isEmpty)
          const Text(
            'No shared activity yet. Create or join a live plan to see updates here.',
          ),
        for (final event in store.activityFeed.take(80))
          ListTile(
            leading: const Icon(Icons.notifications_none_rounded),
            title: Text(event['title'] as String),
            subtitle: Text(
              const {
                    'created': 'Plan created',
                    'joined': 'Someone joined',
                    'card': 'Preferences changed',
                    'options': 'Activities changed',
                    'proposal': 'A proposal is ready for your vote',
                    'vote': 'A vote was updated',
                    'confirmed': 'Everyone agreed. Your plan is confirmed.',
                    'plan': 'Plan details changed',
                  }[event['type']] ??
                  'Plan updated',
            ),
            onTap: () {
              final target = store.liveRooms
                  .where((r) => r.id == event['roomId'])
                  .firstOrNull;
              if (target != null) {
                perform(context, store, () => store.openRoom(target));
              }
            },
          ),
      ],
    ),
  );
}

Future<void> showDiscovery(BuildContext context, MeetStore store) =>
    showDialog<void>(
      context: context,
      builder: (_) => DiscoveryDialog(store: store),
    );

class DiscoveryDialog extends StatefulWidget {
  const DiscoveryDialog({super.key, required this.store});
  final MeetStore store;
  @override
  State<DiscoveryDialog> createState() => _DiscoveryDialogState();
}

class _DiscoveryDialogState extends State<DiscoveryDialog> {
  String area = 'downtown', interest = 'coffee';
  List<Venue> venues = [];
  bool working = false;
  String? error;
  Future<void> search({bool refresh = false}) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final found = await widget.store.discovery.search(
        widget.store.data.areas.firstWhere((a) => a['id'] == area),
        interest,
        refresh: refresh,
      );
      if (mounted) setState(() => venues = found);
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PlanDialog(
    title: 'Find somewhere real.',
    subtitle: 'OpenStreetMap places near Toronto neighbourhoods. Review prices, hours and access before proposing a plan.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: area,
          decoration: const InputDecoration(labelText: 'Neighbourhood'),
          items: widget.store.data.areas
              .map(
                (a) => DropdownMenuItem(
                  value: a['id'] as String,
                  child: Text(a['name'] as String),
                ),
              )
              .toList(),
          onChanged: working ? null : (v) => setState(() => area = v!),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: interest,
          decoration: const InputDecoration(labelText: 'Activity'),
          items: widget.store.data.interests
              .map(
                (a) => DropdownMenuItem(
                  value: a['id'] as String,
                  child: Text(a['name'] as String),
                ),
              )
              .toList(),
          onChanged: working ? null : (v) => setState(() => interest = v!),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: working ? null : search,
          child: Text(working ? 'Finding places…' : 'Search nearby places'),
        ),
        if (working) const LinearProgressIndicator(),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        for (final venue in venues)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: GlassSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    venue.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${venue.json["address"]}\nListed hours: ${venue.json["openingHours"]}\nListed fee: ${venue.json["fee"] ?? "Not provided"}\nListed wheelchair access: ${venue.json["access"]}',
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                  const Text(
                    'Price, quietness and access are not independently verified.',
                    style: TextStyle(fontSize: 11, color: MH.secondary),
                  ),
                  TextButton(
                    onPressed: () => launchUrl(Uri.parse(venue.sourceUrl)),
                    child: const Text('View source'),
                  ),
                  if (widget.store.isHost)
                    OutlinedButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => AddOptionDialog(
                          store: widget.store,
                          seed: {
                            'name': venue.name,
                            'venue': venue.name,
                            'areaId': venue.json['areaId'],
                            'tags': [venue.json['interest']],
                            'description': 'Visit ${venue.name}.',
                            'url': venue.sourceUrl,
                            'lat': venue.json['lat'],
                            'lng': venue.json['lng'],
                            'sourceUrl': venue.sourceUrl,
                            'retrievedAt': venue.json['retrievedAt'],
                            'provider': 'OpenStreetMap',
                            'sourceFacts': venue.sourceFacts,
                          },
                        ),
                      ),
                      child: const Text('Review and add to this plan'),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: () =>
              launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
          child: const Text('© OpenStreetMap contributors · ODbL'),
        ),
        if (venues.isNotEmpty)
          TextButton(
            onPressed: working ? null : () => search(refresh: true),
            child: const Text('Refresh source data'),
          ),
      ],
    ),
  );
}

Future<void> showRoutes(
  BuildContext context,
  MeetStore store,
  Activity activity,
) async {
  if (!await confirmAction(
        context,
        'Check sourced routes?',
        'Your group’s shared neighbourhood centres, travel modes, the venue and plan time will be sent to Transitous. No names, notes or street addresses are sent. This is a free, community service.',
        'Check routes',
      ) ||
      !context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => RouteDialog(store: store, activity: activity),
  );
}

class RouteDialog extends StatefulWidget {
  const RouteDialog({super.key, required this.store, required this.activity});
  final MeetStore store;
  final Activity activity;
  @override
  State<RouteDialog> createState() => _RouteDialogState();
}

class _RouteDialogState extends State<RouteDialog> {
  final results = <String, String>{};
  bool working = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final room = widget.store.room!;
    final rank = widget.store.planner.evaluate(widget.activity, room.members);
    final stops = room.proposal?.stops ?? <Json>[];
    final index = stops.indexWhere(
      (s) => s['candidateId'] == widget.activity.id,
    );
    final minute = index < 0
        ? rank.start ?? 1020
        : stops[index]['startMinute'] as int;
    final previous = index <= 0
        ? null
        : widget.store.planner
              .catalogFor(room)
              .where((a) => a.id == stops[index - 1]['candidateId'])
              .firstOrNull;
    // Toronto's UTC offset is derived for the plan date, not the device zone.
    final departure = torontoInstant(room.date, minute);
    for (final person in room.members) {
      if (!mounted) return;
      if (person.card == null) continue;
      final area = widget.store.data.areas.firstWhere(
        (a) => a['id'] == person.card!.areaId,
      );
      try {
        final route = await widget.store.discovery.route(
          fromLat: previous?.lat ?? (area['lat'] as num).toDouble(),
          fromLng: previous?.lng ?? (area['lng'] as num).toDouble(),
          to: widget.activity,
          mode: person.card!.mode,
          departure: departure,
        );
        if (mounted) {
          setState(
            () => results[person.id] =
                '${route.minutes} min ${previous == null ? "from neighbourhood" : "from ${previous.name}"} · ${person.card!.maxTravel} min outing limit${route.minutes > person.card!.maxTravel ? " · over limit" : ""}\n${route.legs.join("\n")}\nChecked ${DateTime.parse(route.fetchedAt).toLocal()}',
          );
        }
      } catch (e) {
        if (mounted) setState(() => results[person.id] = friendlyError(e));
      }
    }
    if (mounted) setState(() => working = false);
  }

  @override
  Widget build(BuildContext context) => PlanDialog(
    title: 'Routes to ${widget.activity.name}',
    subtitle: 'Sourced routes are a separate check. The shortlist uses labelled estimates; check discrepancies before voting.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (working) const LinearProgressIndicator(),
        for (final person in widget.store.room?.members ?? <Person>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(person.name),
            subtitle: Text(results[person.id] ?? 'Checking…'),
          ),
        TextButton(
          onPressed: () =>
              launchUrl(Uri.parse('https://transitous.org/sources/')),
          child: const Text(
            'Transitous data sources · © OpenStreetMap contributors',
          ),
        ),
        TextButton(
          onPressed: () => launchUrl(Uri.parse(providerContact)),
          child: const Text('MeetHalfway source and contact'),
        ),
      ],
    ),
  );
}

Future<void> showItinerary(BuildContext context, MeetStore store) =>
    showDialog<void>(
      context: context,
      builder: (_) => ItineraryDialog(store: store),
    );

class ItineraryDialog extends StatefulWidget {
  const ItineraryDialog({super.key, required this.store});
  final MeetStore store;
  @override
  State<ItineraryDialog> createState() => _ItineraryDialogState();
}

class _ItineraryDialogState extends State<ItineraryDialog> {
  final selected = <Activity>[];
  @override
  Widget build(BuildContext context) {
    final store = widget.store, room = store.room!;
    final result = store.planner.itinerary(selected, room.members);
    return PlanDialog(
      title: 'Make an afternoon of it.',
      subtitle: 'Choose two or three stops in order. Total cost and travel must respect every person’s limits.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final activity in store.planner.catalogFor(room))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(activity.name),
              subtitle: Text(
                '${activity.duration} min · \$${activity.cost} each',
              ),
              value: selected.any((a) => a.id == activity.id),
              onChanged: (v) => setState(() {
                if (v == true && selected.length < 3) {
                  selected.add(activity);
                } else {
                  selected.removeWhere((a) => a.id == activity.id);
                }
              }),
            ),
          for (final (i, activity) in selected.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${i + 1}. ${activity.name}'),
              trailing: IconButton(
                icon: const Icon(Icons.arrow_upward),
                tooltip: 'Move earlier',
                onPressed: i == 0
                    ? null
                    : () => setState(() {
                        selected.removeAt(i);
                        selected.insert(i - 1, activity);
                      }),
              ),
            ),
          if (selected.length >= 2) ...[
            OutlinedButton.icon(
              onPressed: store.busy
                  ? null
                  : () async {
                      await showRoutingConsent(
                        context,
                        store,
                        itinerary: selected,
                      );
                      if (mounted) setState(() {});
                    },
              icon: const Icon(Icons.alt_route_rounded),
              label: const Text('Use sourced routes for these stops'),
            ),
            Text('Total: \$${result.cost} per person'),
            for (final stop in result.stops)
              Text(
                '${timeLabel(stop["startMinute"] as int)} · ${selected.firstWhere((a) => a.id == stop["candidateId"]).name}',
              ),
            for (final reason in result.reasons)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(reason),
              ),
            const SizedBox(height: 10),
            Text(
              widget.store.planner.routed
                  ? 'Travel between stops uses current Transitous routes. Missing or expired routes need refreshing before proposing.'
                  : 'Travel between stops uses neighbourhood estimates. Check sourced routes before the group votes.',
              style: TextStyle(fontSize: 11, color: MH.secondary),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(
            onPressed: result.eligible && !store.busy
                ? () async {
                    if (await perform(
                          context,
                          store,
                          () => store.proposeItinerary(selected),
                        ) &&
                        context.mounted) {
                      Navigator.pop(context);
                    }
                  }
                : null,
            child: const Text('Propose this itinerary'),
          ),
        ],
      ),
    );
  }
}
