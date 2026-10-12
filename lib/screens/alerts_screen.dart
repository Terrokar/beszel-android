import 'package:beszel_pro/models/alert.dart';
import 'package:beszel_pro/models/records.dart';
import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/screens/dashboard_screen.dart' show describeHubAlert;
import 'package:beszel_pro/services/alert_manager.dart';
import 'package:beszel_pro/services/beszel_api.dart';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';

class AlertsScreen extends StatefulWidget {
  final List<System> systems;

  const AlertsScreen({super.key, this.systems = const []});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  final _api = BeszelApi();
  List<HubAlertEvent> _history = [];
  List<HubAlertRule> _rules = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.fetchAlertHistory(),
        _api.fetchAlertRules(),
      ]);
      if (!mounted) return;
      setState(() {
        _history = results[0] as List<HubAlertEvent>;
        _rules = results[1] as List<HubAlertRule>;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _systemName(String id, [String fallback = '']) {
    for (final s in widget.systems) {
      if (s.id == id) return s.name;
    }
    return fallback.isNotEmpty ? fallback : id;
  }

  String _fmtDate(DateTime? d) =>
      d == null ? '-' : DateFormat('yyyy-MM-dd HH:mm').format(d);

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('alerts')),
          bottom: TabBar(
            tabs: [
              Tab(text: tr('alerts_hub')),
              Tab(text: tr('alerts_rules')),
              Tab(text: tr('alerts_local')),
            ],
          ),
        ),
        body: TabBarView(
          children: [_buildHistory(), _buildRules(), _buildLocal()],
        ),
      ),
    );
  }

  Widget _wrap(List<Widget> children, {String? empty}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (_loading && children.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red))
          else if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Center(
                child: Text(
                  empty ?? tr('no_alerts'),
                  style: const TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildHistory() {
    final active = _history.where((e) => e.isActive).toList();
    final resolved = _history.where((e) => !e.isActive).toList();
    Widget tile(HubAlertEvent e) => Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          e.isActive ? Icons.error : Icons.check_circle,
          color: e.isActive ? Colors.red : Colors.green,
        ),
        title: Text(_systemName(e.systemId, e.systemName)),
        subtitle: Text(
          '${describeHubAlert(e)}\n${_fmtDate(e.created)}'
          '${e.resolved != null ? ' → ${_fmtDate(e.resolved)}' : ''}',
        ),
        isThreeLine: true,
        trailing: e.isActive
            ? null
            : IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  try {
                    await _api.deleteAlertHistory(e.id);
                    setState(() => _history.remove(e));
                  } catch (_) {}
                },
              ),
      ),
    );
    return _wrap([
      if (active.isNotEmpty) ...[
        _header(tr('alerts_active', args: ['${active.length}'])),
        for (final e in active) tile(e),
      ],
      if (resolved.isNotEmpty) ...[
        _header(tr('alerts_resolved')),
        for (final e in resolved) tile(e),
      ],
    ]);
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  Widget _buildRules() {
    final bySystem = <String, List<HubAlertRule>>{};
    for (final r in _rules) {
      bySystem.putIfAbsent(r.systemId, () => []).add(r);
    }
    final ids = bySystem.keys.toList()
      ..sort((a, b) => _systemName(a).compareTo(_systemName(b)));
    return _wrap([
      for (final id in ids)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _systemName(id),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in bySystem[id]!)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          r.triggered
                              ? Icons.notifications_active
                              : Icons.notifications_none,
                          size: 16,
                          color: r.triggered ? Colors.red : null,
                        ),
                        label: Text(_ruleLabel(r)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ], empty: tr('no_alert_rules'));
  }

  String _ruleLabel(HubAlertRule r) {
    final key = 'alert_name_${r.name}';
    var name = key.tr();
    if (name == key) name = r.name;
    final binary = const {'Status', 'ContainerHealth', 'SystemdFailed'};
    final parts = <String>[name];
    if (!binary.contains(r.name)) {
      final unit = switch (r.name) {
        'Temperature' => ' °C',
        'Bandwidth' => ' MB/s',
        'LoadAvg1' || 'LoadAvg5' || 'LoadAvg15' => '',
        _ => '%',
      };
      final op = r.name == 'Battery' ? '<' : '>';
      parts.add('$op ${r.value.toStringAsFixed(r.value % 1 == 0 ? 0 : 1)}$unit');
    }
    if (r.min > 0) parts.add('${r.min} min');
    return parts.join(' · ');
  }

  Widget _buildLocal() {
    return Consumer<AlertManager>(
      builder: (context, manager, _) {
        final alerts = manager.alerts;
        return Column(
          children: [
            if (alerts.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: manager.clearAlerts,
                  icon: const Icon(Icons.delete_sweep),
                  label: Text(tr('clear_all')),
                ),
              ),
            Expanded(
              child: alerts.isEmpty
                  ? Center(
                      child: Text(
                        tr('no_alerts'),
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: alerts.length,
                      itemBuilder: (context, index) =>
                          _localTile(alerts[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _localTile(Alert alert) {
    final date = DateTime.fromMillisecondsSinceEpoch(alert.timestamp);
    final (color, icon) = switch (alert.type) {
      'error' => (Colors.red, Icons.error),
      'warning' => (Colors.orange, Icons.warning),
      _ => (Colors.blue, Icons.info),
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Icon(icon, color: color, size: 30),
        title: Text(
          alert.title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${alert.message}\n${DateFormat('yyyy-MM-dd HH:mm:ss').format(date)}',
        ),
        isThreeLine: true,
      ),
    );
  }
}
