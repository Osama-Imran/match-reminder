import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:permission_handler/permission_handler.dart';

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MatchReminderApp());
}

class MatchReminderApp extends StatelessWidget {
  const MatchReminderApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Match Reminder',
      theme: ThemeData(primarySwatch: Colors.green, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class Team {
  final String id;
  final String name;
  final String league;
  final String badge;
  Team(
      {required this.id,
      required this.name,
      required this.league,
      required this.badge});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'league': league, 'badge': badge};
  factory Team.fromJson(Map<String, dynamic> j) => Team(
      id: j['id'], name: j['name'], league: j['league'], badge: j['badge']);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Team> selectedTeams = [];
  bool loading = true;
  String status = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    tzdata.initializeTimeZones();
    await _initNotifications();
    await Permission.notification.request();
    await _loadTeams();
    setState(() => loading = false);
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await notificationsPlugin.initialize(initSettings);
    const channel = AndroidNotificationChannel(
      'match_reminders',
      'Match Reminders',
      description: 'Reminders for upcoming matches',
      importance: Importance.high,
    );
    await notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> _loadTeams() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('selected_teams') ?? [];
    setState(() {
      selectedTeams = raw.map((s) => Team.fromJson(jsonDecode(s))).toList();
    });
  }

  Future<void> _saveTeams() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('selected_teams',
        selectedTeams.map((t) => jsonEncode(t.toJson())).toList());
  }

  Future<void> _addTeam() async {
    final result = await Navigator.push<Team>(
        context, MaterialPageRoute(builder: (_) => const SearchTeamPage()));
    if (result != null && !selectedTeams.any((t) => t.id == result.id)) {
      setState(() => selectedTeams.add(result));
      await _saveTeams();
      await _syncMatches();
    }
  }

  Future<void> _removeTeam(Team t) async {
    setState(() => selectedTeams.removeWhere((x) => x.id == t.id));
    await _saveTeams();
  }

  Future<void> _syncMatches() async {
    setState(() => status = 'Syncing matches...');
    int notifId = 0;
    await notificationsPlugin.cancelAll();
    int scheduled = 0;
    for (final team in selectedTeams) {
      try {
        final resp = await http.get(Uri.parse(
            'https://www.thesportsdb.com/api/v1/json/3/eventsnext.php?id=${team.id}'));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final events = data['events'] as List<dynamic>? ?? [];
          for (final e in events) {
            final dateStr = e['dateEvent'];
            final timeStr = e['strTime'];
            if (dateStr == null || timeStr == null) continue;
            final dt = DateTime.tryParse('${dateStr}T$timeStr');
            if (dt == null) continue;
            final matchTimeUtc = tz.TZDateTime.from(dt, tz.getLocation('UTC'));
            final reminderTime = matchTimeUtc.subtract(const Duration(minutes: 30));
            if (reminderTime.isAfter(tz.TZDateTime.now(tz.local))) {
              final home = e['strHomeTeam'] ?? '';
              final away = e['strAwayTeam'] ?? '';
              final league = e['strLeague'] ?? '';
              await notificationsPlugin.zonedSchedule(
                notifId++,
                '$home vs $away',
                '$league starts in 30 minutes',
                tz.TZDateTime.from(reminderTime, tz.local),
                const NotificationDetails(
                  android: AndroidNotificationDetails(
                      'match_reminders', 'Match Reminders',
                      importance: Importance.high, priority: Priority.high),
                ),
                androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
                uiLocalNotificationDateInterpretation:
                    UILocalNotificationDateInterpretation.absoluteTime,
              );
              scheduled++;
            }
          }
        }
      } catch (_) {}
    }
    setState(() => status = '$scheduled reminders scheduled');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Match Reminder')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (status.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.all(8), child: Text(status)),
                Expanded(
                  child: selectedTeams.isEmpty
                      ? const Center(
                          child: Text(
                              'Koi team select nahi hui.\n"+" dabao team add karne ke liye.',
                              textAlign: TextAlign.center))
                      : ListView.builder(
                          itemCount: selectedTeams.length,
                          itemBuilder: (context, i) {
                            final t = selectedTeams[i];
                            return ListTile(
                              leading: t.badge.isNotEmpty
                                  ? Image.network(t.badge,
                                      width: 40,
                                      height: 40,
                                      errorBuilder: (_, __, ___) =>
                                          const Icon(Icons.sports_soccer))
                                  : const Icon(Icons.sports_soccer),
                              title: Text(t.name),
                              subtitle: Text(t.league),
                              trailing: IconButton(
                                  icon: const Icon(Icons.delete,
                                      color: Colors.red),
                                  onPressed: () => _removeTeam(t)),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'sync',
            onPressed: selectedTeams.isEmpty ? null : _syncMatches,
            label: const Text('Sync Matches'),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'add',
            onPressed: _addTeam,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class SearchTeamPage extends StatefulWidget {
  const SearchTeamPage({super.key});
  @override
  State<SearchTeamPage> createState() => _SearchTeamPageState();
}

class _SearchTeamPageState extends State<SearchTeamPage> {
  final controller = TextEditingController();
  List<Team> results = [];
  bool loading = false;

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => loading = true);
    try {
      final resp = await http.get(Uri.parse(
          'https://www.thesportsdb.com/api/v1/json/3/searchteams.php?t=${Uri.encodeComponent(query)}'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final teams = data['teams'] as List<dynamic>?;
        setState(() {
          results = teams == null
              ? []
              : teams
                  .map((t) => Team(
                        id: t['idTeam'].toString(),
                        name: t['strTeam'] ?? '',
                        league: t['strLeague'] ?? '',
                        badge: t['strTeamBadge'] ?? '',
                      ))
                  .toList();
        });
      }
    } catch (_) {
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Team ka naam likho...', border: InputBorder.none),
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => _search(controller.text))
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, i) {
                final t = results[i];
                return ListTile(
                  leading: t.badge.isNotEmpty
                      ? Image.network(t.badge,
                          width: 40,
                          height: 40,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.sports_soccer))
                      : const Icon(Icons.sports_soccer),
                  title: Text(t.name),
                  subtitle: Text(t.league),
                  onTap: () => Navigator.pop(context, t),
                );
              },
            ),
    );
  }
}
