import 'dart:async';

import 'package:beszel_pro/models/records.dart';
import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/providers/app_provider.dart';
import 'package:beszel_pro/screens/alerts_screen.dart';
import 'package:beszel_pro/screens/appearance_screen.dart';
import 'package:beszel_pro/screens/setup_screen.dart';
import 'package:beszel_pro/screens/system_detail_screen.dart';
import 'package:beszel_pro/screens/user_info_screen.dart';
import 'package:beszel_pro/services/alert_manager.dart';
import 'package:beszel_pro/services/beszel_api.dart';
import 'package:beszel_pro/services/biometric_service.dart';
import 'package:beszel_pro/services/notification_service.dart';
import 'package:beszel_pro/services/pin_service.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:beszel_pro/utils/format.dart';
import 'package:beszel_pro/widgets/common.dart';
import 'package:beszel_pro/widgets/language_menu.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SortOption { name, status, cpu, ram, disk }

enum StatusFilter { all, up, down, paused }

/// Signs the user out and returns to the server setup screen.
Future<void> performLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('logout')),
      content: Text(tr('logout_confirm')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('logout')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final navigator = Navigator.of(context, rootNavigator: true);
  try {
    await PocketBaseService().logout();
    await PinService().removePin();
    await BiometricService().setBiometricEnabled(false);
    await AlertManager().clearAlerts();
  } catch (e) {
    debugPrint('Logout cleanup error: $e');
  }
  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const SetupScreen()),
    (route) => false,
  );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _sortKey = 'dashboard_sort';

  final _api = BeszelApi();
  List<System> _systems = [];
  Map<String, List<double>> _cumulativeTraffic = {}; // systemId -> [sent, recv]
  bool _isLoading = true;
  bool _isOffline = false;
  String? _error;
  SortOption _currentSort = SortOption.name;
  StatusFilter _statusFilter = StatusFilter.all;
  String _query = '';
  bool _searching = false;
  Timer? _pollingTimer;
  UnsubscribeFunc? _systemsUnsub;
  UnsubscribeFunc? _alertsUnsub;
  int _activeHubAlerts = 0;

  /// Keys (`systemId:type`) of local threshold alerts currently raised,
  /// so each condition notifies once until it clears again.
  final Set<String> _raised = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prefs = await SharedPreferences.getInstance();
      final sort = prefs.getString(_sortKey);
      _currentSort = SortOption.values.firstWhere(
        (s) => s.name == sort,
        orElse: () => SortOption.name,
      );
      NotificationService().initialize();
      AlertManager().loadAlerts();
      await _fetchSystems();
      _subscribeToRealtime();
      _subscribeToHubAlerts();
      _pollingTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _pollSystems(),
      );
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _unsubscribe(_systemsUnsub);
    _unsubscribe(_alertsUnsub);
    super.dispose();
  }

  void _unsubscribe(UnsubscribeFunc? f) {
    if (f == null) return;
    f().catchError((_) {});
  }

  // ---------------------------------------------------------------- data

  void _sortSystems() {
    int byName(System a, System b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    switch (_currentSort) {
      case SortOption.name:
        _systems.sort(byName);
      case SortOption.status:
        const order = {'down': 0, 'pending': 1, 'up': 2, 'paused': 3};
        _systems.sort((a, b) {
          final c = (order[a.status] ?? 9).compareTo(order[b.status] ?? 9);
          return c != 0 ? c : byName(a, b);
        });
      case SortOption.cpu:
        _systems.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
      case SortOption.ram:
        _systems.sort((a, b) => b.memoryPercent.compareTo(a.memoryPercent));
      case SortOption.disk:
        _systems.sort((a, b) => b.diskPercent.compareTo(a.diskPercent));
    }
  }

  List<System> get _visibleSystems {
    final q = _query.trim().toLowerCase();
    return _systems.where((s) {
      if (_statusFilter == StatusFilter.up && !s.isUp) return false;
      if (_statusFilter == StatusFilter.down && !s.isDown) return false;
      if (_statusFilter == StatusFilter.paused && !s.isPaused) return false;
      if (q.isEmpty) return true;
      return s.name.toLowerCase().contains(q) ||
          s.host.toLowerCase().contains(q) ||
          (s.agentVersion ?? '').contains(q);
    }).toList();
  }

  Future<void> _pollSystems() async {
    try {
      final newSystems = await _api.fetchSystems();
      if (!mounted) return;
      setState(() {
        for (final s in newSystems) {
          _checkAlerts(s);
        }
        _systems = newSystems;
        _sortSystems();
      });
      _fetchActiveHubAlerts();
    } catch (_) {}
  }

  Future<void> _fetchSystems({bool retried = false}) async {
    if (mounted) {
      setState(() {
        _isOffline = false;
        _error = null;
      });
    }

    try {
      final systems = await _api.fetchSystems();
      if (!mounted) return;
      setState(() {
        _systems = systems;
        _sortSystems();
        for (final s in _systems) {
          _checkAlerts(s);
        }
        _isLoading = false;
      });
      _fetchCumulativeTraffic();
      _fetchActiveHubAlerts();
    } catch (e) {
      if (!mounted) return;
      final errString = e.toString();
      debugPrint('Fetch error: $errString');
      if (!retried &&
          e is ClientException &&
          (e.statusCode == 401 || e.statusCode == 403)) {
        // Session expired or revoked - try to refresh the auth token once.
        var refreshed = false;
        try {
          await PocketBaseService().pb.collection('users').authRefresh();
          refreshed = true;
        } catch (_) {}
        if (refreshed) return _fetchSystems(retried: true);
      }
      setState(() {
        if (e is ClientException && e.statusCode == 0) {
          _isOffline = true;
        } else {
          _error = '${tr('failed_load_systems')}\n$e';
        }
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchActiveHubAlerts() async {
    try {
      final pb = PocketBaseService().pb;
      final res = await pb
          .collection('alerts_history')
          .getList(page: 1, perPage: 1, filter: 'resolved = null', fields: 'id');
      if (mounted) setState(() => _activeHubAlerts = res.totalItems);
    } catch (_) {}
  }

  Future<void> _fetchCumulativeTraffic() async {
    final pb = PocketBaseService().pb;
    final Map<String, List<double>> trafficMap = {};
    for (final system in List<System>.of(_systems)) {
      if (!system.isUp) continue;
      try {
        final res = await pb
            .collection('system_stats')
            .getList(
              page: 1,
              perPage: 1,
              filter: pb.filter('system = {:id} && type = "1m"', {
                'id': system.id,
              }),
              sort: '-created',
              fields: 'stats.ni',
            );
        if (res.items.isEmpty) continue;
        final ni = asMap(asMap(res.items.first.data['stats'])['ni']);
        double sent = 0, recv = 0;
        for (final v in ni.values) {
          final l = asDoubleList(v);
          if (l.length >= 4) {
            sent += l[2];
            recv += l[3];
          }
        }
        trafficMap[system.id] = [sent, recv];
      } catch (e) {
        debugPrint('Failed to fetch stats for ${system.name}: $e');
      }
    }
    if (mounted) setState(() => _cumulativeTraffic = trafficMap);
  }

  Future<void> _subscribeToRealtime() async {
    try {
      _systemsUnsub = await PocketBaseService().pb
          .collection('systems')
          .subscribe('*', (e) {
            if (!mounted || e.record == null) return;
            final sys = System.fromRecord(e.record!);
            setState(() {
              final index = _systems.indexWhere((s) => s.id == sys.id);
              if (e.action == 'delete') {
                _systems.removeWhere((s) => s.id == sys.id);
              } else if (index == -1) {
                _systems.add(sys);
              } else {
                _checkAlerts(sys);
                _systems[index] = sys;
              }
              _sortSystems();
            });
          });
    } catch (e) {
      debugPrint('Realtime subscription failed: $e');
    }
  }

  /// Hub alerts (configured in the Beszel web UI) arrive as
  /// `alerts_history` records - surface them as notifications.
  Future<void> _subscribeToHubAlerts() async {
    try {
      _alertsUnsub = await PocketBaseService().pb
          .collection('alerts_history')
          .subscribe('*', (e) {
            if (!mounted || e.record == null) return;
            _fetchActiveHubAlerts();
            if (e.action != 'create') return;
            final event = HubAlertEvent.fromRecord(e.record!);
            final system = _systems.where((s) => s.id == event.systemId);
            final systemName = system.isNotEmpty
                ? system.first.name
                : event.systemName;
            final title = tr('hub_alert_title', args: [systemName]);
            final body = describeHubAlert(event);
            NotificationService().showNotification(
              id: event.id.hashCode,
              title: title,
              body: body,
            );
            AlertManager().addAlert(title, body, 'error', systemName);
          });
    } catch (e) {
      debugPrint('Alert subscription failed: $e');
    }
  }

  // -------------------------------------------------------- local alerts

  void _checkAlerts(System s) {
    if (s.isPaused || s.isPending) {
      _raised.removeWhere((k) => k.startsWith('${s.id}:'));
      return;
    }
    _evaluate(
      s,
      'down',
      s.isDown,
      tr('alert_system_down_title'),
      tr('alert_system_down_body', args: [s.name]),
      'error',
    );
    if (!s.isUp) return;
    _evaluate(
      s,
      'cpu',
      s.cpuPercent > 80,
      tr('alert_high_cpu_title'),
      tr('alert_high_cpu_body', args: [s.name, s.cpuPercent.toStringAsFixed(1)]),
      'warning',
    );
    _evaluate(
      s,
      'ram',
      s.memoryPercent > 80,
      tr('alert_high_ram_title'),
      tr(
        'alert_high_ram_body',
        args: [s.name, s.memoryPercent.toStringAsFixed(1)],
      ),
      'warning',
    );
    _evaluate(
      s,
      'disk',
      s.diskPercent > 80,
      tr('alert_high_disk_title'),
      tr(
        'alert_high_disk_body',
        args: [s.name, s.diskPercent.toStringAsFixed(1)],
      ),
      'warning',
    );
  }

  void _evaluate(
    System s,
    String type,
    bool condition,
    String title,
    String body,
    String level,
  ) {
    final key = '${s.id}:$type';
    if (!condition) {
      _raised.remove(key);
      return;
    }
    if (!_raised.add(key)) return;
    NotificationService().showNotification(
      id: key.hashCode,
      title: title,
      body: body,
    );
    AlertManager().addAlert(title, body, level, s.name);
  }

  // ------------------------------------------------------------------ ui

  Widget _buildOfflineWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.signal_wifi_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            tr('no_internet'),
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              setState(() => _isLoading = true);
              _fetchSystems();
            },
            icon: const Icon(Icons.refresh),
            label: Text(tr('refresh')),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                setState(() => _isLoading = true);
                _fetchSystems();
              },
              icon: const Icon(Icons.refresh),
              label: Text(tr('refresh')),
            ),
            TextButton(
              onPressed: () => performLogout(context),
              child: Text(tr('logout')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context) {
    final total = _systems.length;
    final up = _systems.where((s) => s.isUp).length;
    final down = _systems.where((s) => s.isDown).length;
    final paused = _systems.where((s) => s.isPaused).length;

    double totalBandwidth = 0;
    for (final sys in _systems) {
      totalBandwidth += sys.bandwidth;
    }
    double totalSent = 0, totalRecv = 0;
    for (final t in _cumulativeTraffic.values) {
      totalSent += t[0];
      totalRecv += t[1];
    }

    Widget stat(String label, int value, Color color, StatusFilter filter) {
      final selected = _statusFilter == filter;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(
          () => _statusFilter = selected ? StatusFilter.all : filter,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: selected ? Border.all(color: color) : null,
          ),
          child: Column(
            children: [
              Text(
                '$value',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                stat(tr('total'), total, Colors.blue, StatusFilter.all),
                stat(tr('online'), up, Colors.green, StatusFilter.up),
                stat(tr('offline'), down, Colors.red, StatusFilter.down),
                if (paused > 0)
                  stat(
                    tr('status_paused'),
                    paused,
                    Colors.blueGrey,
                    StatusFilter.paused,
                  ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.network_check, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${tr('bandwidth')}: ${formatBytesRate(totalBandwidth)}',
                  ),
                ),
              ],
            ),
            if (_cumulativeTraffic.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.data_usage, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${tr('traffic')}: ↑${formatBytes(totalSent)} / ↓${formatBytes(totalRecv)}',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        Widget option(SortOption o, IconData icon, String label) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          trailing: _currentSort == o ? const Icon(Icons.check) : null,
          onTap: () async {
            setState(() {
              _currentSort = o;
              _sortSystems();
            });
            Navigator.pop(context);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_sortKey, o.name);
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              option(SortOption.name, Icons.sort_by_alpha, tr('sort_name')),
              option(SortOption.status, Icons.traffic, tr('status')),
              option(SortOption.cpu, Icons.memory, tr('sort_cpu')),
              option(SortOption.ram, Icons.storage, tr('sort_ram')),
              option(SortOption.disk, Icons.donut_large, tr('disk')),
            ],
          ),
        );
      },
    );
  }

  void _onMenu(String value) {
    switch (value) {
      case 'user':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const UserInfoScreen()));
      case 'theme':
        final provider = Provider.of<AppProvider>(context, listen: false);
        provider.toggleTheme(
          Theme.of(context).brightness != Brightness.dark,
        );
      case 'language':
        showLanguageDialog(context);
      case 'appearance':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AppearanceScreen(fromSettings: true),
          ),
        );
      case 'logout':
        performLogout(context);
    }
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr('search'),
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : Text(tr('dashboard')),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: tr('search'),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _query = '';
            }),
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: tr('sort_by'),
            onPressed: _showSortSheet,
          ),
          Consumer<AlertManager>(
            builder: (context, alertManager, child) {
              final count = alertManager.alerts.length + _activeHubAlerts;
              return IconButton(
                icon: Badge(
                  isLabelVisible: count > 0,
                  label: _activeHubAlerts > 0 ? Text('$_activeHubAlerts') : null,
                  smallSize: 10,
                  child: const Icon(Icons.notifications),
                ),
                tooltip: tr('alerts'),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AlertsScreen(systems: _systems),
                    ),
                  );
                  _fetchActiveHubAlerts();
                },
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle),
            tooltip: 'menu_user'.tr(),
            onSelected: _onMenu,
            itemBuilder: (BuildContext context) => [
              _menuItem('user', Icons.person, 'menu_user'.tr()),
              _menuItem(
                'theme',
                isDark ? Icons.light_mode : Icons.dark_mode,
                'menu_theme'.tr(),
              ),
              _menuItem('appearance', Icons.view_quilt, 'appearance'.tr()),
              _menuItem('language', Icons.language, 'menu_language'.tr()),
              const PopupMenuDivider(),
              _menuItem('logout', Icons.logout, tr('logout')),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isOffline
          ? _buildOfflineWidget()
          : _error != null
          ? _buildErrorWidget()
          : RefreshIndicator(
              onRefresh: _fetchSystems,
              child: Builder(
                builder: (context) {
                  final isDetailed = Provider.of<AppProvider>(
                    context,
                  ).isDetailed;
                  final systems = _visibleSystems;
                  final header = isDetailed ? 1 : 0;
                  if (_systems.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 120),
                        Center(child: Text(tr('no_systems'))),
                      ],
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(8.0),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: systems.length + header,
                    itemBuilder: (context, index) {
                      if (isDetailed && index == 0) {
                        return _buildSummaryCard(context);
                      }
                      final system = systems[index - header];
                      return SystemCard(
                        system: system,
                        isDetailed: isDetailed,
                        cumulativeTraffic: _cumulativeTraffic[system.id],
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}

/// Human readable text for an `alerts_history` entry. Except for network
/// monitors (actual loss), `value` is the configured threshold.
String describeHubAlert(HubAlertEvent e) {
  final v = e.value;
  final name = e.name;
  String value;
  switch (name) {
    case 'CPU':
    case 'Memory':
    case 'Disk':
    case 'GPU':
    case 'CPUIOWait':
    case 'CPUSteal':
      value = '> ${formatPercent(v)}';
    case 'Battery':
      value = '< ${formatPercent(v)}';
    case 'NetworkMonitorLoss':
      value = formatPercent(v);
    case 'Temperature':
      value = '> ${formatTemp(v)}';
    case 'Bandwidth':
      value = '> ${v.toStringAsFixed(2)} MB/s';
    case 'LoadAvg1':
    case 'LoadAvg5':
    case 'LoadAvg15':
      value = '> ${v.toStringAsFixed(2)}';
    default:
      value = '';
  }
  final key = 'alert_name_$name';
  var label = key.tr();
  if (label == key) label = name;
  if (e.monitorName.isNotEmpty) label = '$label · ${e.monitorName}';
  if (value.isEmpty) return label;
  return name == 'NetworkMonitorLoss' ? '$label: $value' : '$label $value';
}

class SystemCard extends StatelessWidget {
  final System system;
  final bool isDetailed;
  final List<double>? cumulativeTraffic; // [sent, recv]

  const SystemCard({
    super.key,
    required this.system,
    this.isDetailed = false,
    this.cumulativeTraffic,
  });

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SystemDetailScreen(system: system)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inactive = !system.isUp;
    return Opacity(
      opacity: system.isPaused ? 0.6 : 1,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        elevation: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context),
                if (inactive && system.hasNoData)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'status_${system.status}_hint'.tr(),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  )
                else if (isDetailed)
                  ..._buildDetailed(context)
                else
                  ..._buildSimple(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final failedServices = system.services.length >= 2
        ? system.services[1]
        : 0;
    return Row(
      children: [
        osIcon(system.os),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                system.name,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (!isDetailed)
                Text(
                  system.host,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (failedServices > 0) ...[
          Pill(
            text: '$failedServices',
            color: Colors.red,
            icon: Icons.miscellaneous_services,
          ),
          const SizedBox(width: 6),
        ],
        if (system.pendingUpdates.isNotEmpty && system.pendingUpdates[0] > 0) ...[
          Pill(
            text: '${system.pendingUpdates[0]}',
            color: Colors.orange,
            icon: Icons.system_update_alt,
          ),
          const SizedBox(width: 6),
        ],
        StatusBadge(status: system.status),
      ],
    );
  }

  List<Widget> _buildSimple(BuildContext context) {
    final temp = system.temperature;
    final gpu = system.gpuPercent;
    return [
      const Divider(height: 24),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat(tr('cpu'), formatPercent(system.cpuPercent), Icons.memory,
              usageColor(system.cpuPercent)),
          _stat(tr('ram'), formatPercent(system.memoryPercent), Icons.storage,
              usageColor(system.memoryPercent)),
          _stat(tr('disk'), formatPercent(system.diskPercent),
              Icons.donut_large, usageColor(system.diskPercent)),
          if (gpu != null)
            _stat('GPU', formatPercent(gpu), Icons.videogame_asset_outlined,
                usageColor(gpu)),
          if (temp != null)
            _stat(tr('temp_short'), '${temp.toStringAsFixed(0)}°',
                Icons.thermostat, tempColor(temp)),
        ],
      ),
    ];
  }

  Widget _stat(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  List<Widget> _buildDetailed(BuildContext context) {
    final la = system.loadAvg;
    final services = system.services;
    final battery = system.battery;
    String traffic = '-';
    if (cumulativeTraffic != null && cumulativeTraffic!.length >= 2) {
      traffic =
          '↑${formatBytes(cumulativeTraffic![0])} / ↓${formatBytes(cumulativeTraffic![1])}';
    }

    return [
      const SizedBox(height: 14),
      UsageBar(label: 'CPU', percent: system.cpuPercent, icon: Icons.memory),
      const SizedBox(height: 8),
      UsageBar(
        label: tr('ram'),
        percent: system.memoryPercent,
        icon: Icons.storage,
      ),
      const SizedBox(height: 8),
      UsageBar(
        label: system.rootDiskName ?? tr('disk'),
        percent: system.diskPercent,
        icon: Icons.donut_large,
      ),
      for (final e in system.extraFs.entries) ...[
        const SizedBox(height: 8),
        UsageBar(label: e.key, percent: e.value, icon: Icons.donut_large),
      ],
      if (system.gpuPercent != null) ...[
        const SizedBox(height: 8),
        UsageBar(
          label: 'GPU',
          percent: system.gpuPercent!,
          icon: Icons.videogame_asset_outlined,
        ),
      ],
      const SizedBox(height: 12),
      if (la.isNotEmpty)
        _infoRow(
          Icons.speed,
          tr('load'),
          la.map((v) => v.toStringAsFixed(2)).join(' '),
        ),
      _infoRow(Icons.network_check, tr('network'), formatBytesRate(system.bandwidth)),
      if (cumulativeTraffic != null)
        _infoRow(Icons.data_usage, tr('traffic'), traffic),
      if (system.temperature != null)
        _infoRow(Icons.thermostat, tr('temperature'), formatTemp(system.temperature)),
      if (battery != null)
        _infoRow(
          Icons.battery_std,
          tr('battery'),
          '${battery.$1}% · ${tr('battery_${battery.$2.name}')}',
        ),
      _infoRow(Icons.schedule, tr('uptime'), formatUptime(system.uptime)),
      if (services.length >= 2 && services[0] > 0)
        _infoRow(
          Icons.miscellaneous_services,
          tr('services'),
          '${services[0]} (${tr('failed')}: ${services[1]})',
        ),
      if (system.agentVersion != null)
        _infoRow(Icons.sell_outlined, tr('agent_version'), system.agentVersion!),
    ];
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: Colors.grey)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
