import 'dart:async';
import 'dart:math' as math;

import 'package:beszel_pro/models/records.dart';
import 'package:beszel_pro/models/stats.dart';
import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/services/beszel_api.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:beszel_pro/utils/format.dart';
import 'package:beszel_pro/widgets/common.dart';
import 'package:beszel_pro/widgets/time_series_chart.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _Tab {
  overview(Icons.dashboard_outlined),
  cpu(Icons.memory),
  memory(Icons.storage),
  disk(Icons.disc_full),
  network(Icons.swap_vert),
  sensors(Icons.thermostat),
  gpu(Icons.videogame_asset_outlined),
  containers(Icons.view_in_ar_outlined),
  services(Icons.miscellaneous_services),
  smart(Icons.health_and_safety_outlined);

  final IconData icon;
  const _Tab(this.icon);

  bool get hasCharts =>
      this != _Tab.containers && this != _Tab.services && this != _Tab.smart;
}

class SystemDetailScreen extends StatefulWidget {
  final System system;

  const SystemDetailScreen({super.key, required this.system});

  @override
  State<SystemDetailScreen> createState() => _SystemDetailScreenState();
}

class _SystemDetailScreenState extends State<SystemDetailScreen> {
  static const _rangePrefKey = 'chart_range';

  final _api = BeszelApi();

  late System _system = widget.system;
  SystemDetails? _details;
  ChartRange _range = ChartRange.hour;
  List<StatsPoint> _points = [];
  List<ContainerInfo> _containers = [];
  List<SystemdService> _services = [];
  List<SmartDevice> _smart = [];

  bool _initialLoading = true;
  bool _historyLoading = false;
  String? _error;
  bool _smartRefreshing = false;

  UnsubscribeFunc? _systemUnsub;
  UnsubscribeFunc? _liveUnsub;
  Timer? _refreshTimer;
  int _historyRequest = 0;

  String _serviceFilter = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _systemUnsub?.call().catchError((_) {});
    _liveUnsub?.call().catchError((_) {});
    super.dispose();
  }

  bool get _liveSupported =>
      _system.isUp && versionAtLeast(_system.agentVersion, '0.13.0');

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    var range = ChartRange.fromLabel(prefs.getString(_rangePrefKey));
    if (range == ChartRange.live && !_liveSupported) range = ChartRange.hour;
    _range = range;

    _subscribeSystem();
    await Future.wait([
      _loadHistory(),
      _loadDetails(),
      _loadContainers(),
      _loadServices(),
      _loadSmart(),
    ]);
    if (mounted) setState(() => _initialLoading = false);
    _applyRange();
  }

  Future<void> _subscribeSystem() async {
    try {
      _systemUnsub = await PocketBaseService().pb
          .collection('systems')
          .subscribe(_system.id, (e) {
            if (!mounted || e.record == null) return;
            setState(() => _system = System.fromRecord(e.record!));
          });
    } catch (e) {
      debugPrint('System subscription failed: $e');
    }
  }

  Future<void> _loadDetails() async {
    final d = await _api.fetchDetails(_system);
    if (mounted) setState(() => _details = d);
  }

  Future<void> _loadContainers() async {
    if (!versionAtLeast(_system.agentVersion, '0.14.0')) return;
    try {
      final c = await _api.fetchContainers(_system.id);
      if (mounted) setState(() => _containers = c);
    } catch (e) {
      debugPrint('containers: $e');
    }
  }

  Future<void> _loadServices() async {
    try {
      final s = await _api.fetchServices(_system.id);
      if (mounted) setState(() => _services = s);
    } catch (e) {
      debugPrint('services: $e');
    }
  }

  Future<void> _loadSmart() async {
    try {
      final s = await _api.fetchSmartDevices(_system.id);
      if (mounted) setState(() => _smart = s);
    } catch (e) {
      debugPrint('smart: $e');
    }
  }

  Future<void> _loadHistory() async {
    if (_range == ChartRange.live) return;
    final request = ++_historyRequest;
    setState(() {
      _historyLoading = true;
      _error = null;
    });
    try {
      final points = await _api.fetchStats(_system.id, _range);
      if (!mounted || request != _historyRequest) return;
      setState(() => _points = points);
    } catch (e) {
      if (mounted && request == _historyRequest) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && request == _historyRequest) {
        setState(() => _historyLoading = false);
      }
    }
  }

  /// Starts live streaming or periodic history refresh for the current range.
  void _applyRange() {
    _refreshTimer?.cancel();
    _liveUnsub?.call().catchError((_) {});
    _liveUnsub = null;

    if (_range == ChartRange.live) {
      _startLive();
      return;
    }
    final every = _range.expectedInterval < const Duration(minutes: 2)
        ? const Duration(minutes: 1)
        : const Duration(minutes: 5);
    _refreshTimer = Timer.periodic(every, (_) {
      _loadHistory();
      _loadContainers();
      _loadServices();
    });
  }

  Future<void> _startLive() async {
    setState(() {
      _points = [];
      _historyLoading = true;
    });
    try {
      _liveUnsub = await _api.subscribeLive(_system.id, (data) {
        if (!mounted || _range != ChartRange.live) return;
        setState(() {
          _historyLoading = false;
          final stats = asMap(data['stats']);
          if (stats.isNotEmpty) {
            _points = [..._points, StatsPoint(DateTime.now(), stats)];
            if (_points.length > 60) {
              _points = _points.sublist(_points.length - 60);
            }
          }
          final info = asMap(data['info']);
          if (info.isNotEmpty) {
            _system = System(
              id: _system.id,
              name: _system.name,
              host: _system.host,
              port: _system.port,
              status: _system.status,
              updated: _system.updated,
              info: {..._system.info, ...info},
            );
          }
        });
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _historyLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _setRange(ChartRange range) async {
    if (range == _range) return;
    setState(() {
      _range = range;
      _points = [];
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rangePrefKey, range.label);
    await _loadHistory();
    _applyRange();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _loadHistory(),
      _loadContainers(),
      _loadServices(),
      _loadSmart(),
    ]);
  }

  StatsPoint? get _latest => _points.isEmpty ? null : _points.last;

  List<_Tab> get _tabs {
    final latest = _latest;
    final hasSensors =
        _system.temperature != null ||
        _system.battery != null ||
        (latest != null &&
            (latest.temperatures.isNotEmpty ||
                latest.fans.isNotEmpty ||
                latest.batteries.isNotEmpty));
    final hasGpu =
        _system.gpuPercent != null ||
        (latest != null && latest.gpus.isNotEmpty);
    return [
      _Tab.overview,
      _Tab.cpu,
      _Tab.memory,
      _Tab.disk,
      _Tab.network,
      if (hasSensors) _Tab.sensors,
      if (hasGpu) _Tab.gpu,
      if (_containers.isNotEmpty) _Tab.containers,
      if (_services.isNotEmpty) _Tab.services,
      if (_smart.isNotEmpty) _Tab.smart,
    ];
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (_initialLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(_system.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final tabs = _tabs;
    return DefaultTabController(
      key: ValueKey(tabs.map((t) => t.name).join(',')),
      length: tabs.length,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          return Scaffold(
            appBar: AppBar(
              titleSpacing: 0,
              title: Row(
                children: [
                  osIcon(_details?.os ?? _system.os),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(_system.name, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  StatusBadge(status: _system.status),
                ],
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48 + 44),
                child: Column(
                  children: [
                    TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        for (final t in tabs)
                          Tab(
                            height: 44,
                            icon: null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(t.icon, size: 16),
                                const SizedBox(width: 6),
                                Text('tab_${t.name}'.tr()),
                              ],
                            ),
                          ),
                      ],
                    ),
                    AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => tabs[controller.index].hasCharts
                          ? _buildRangeSelector()
                          : const SizedBox(height: 44),
                    ),
                  ],
                ),
              ),
            ),
            body: TabBarView(
              children: [for (final t in tabs) _buildTab(t)],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRangeSelector() {
    final ranges = [
      if (_liveSupported) ChartRange.live,
      ChartRange.hour,
      ChartRange.halfDay,
      ChartRange.day,
      ChartRange.week,
      ChartRange.month,
    ];
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final r in ranges)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      avatar: r == ChartRange.live
                          ? const Icon(Icons.bolt, size: 16)
                          : null,
                      label: Text('range_${r.label}'.tr()),
                      selected: _range == r,
                      onSelected: (_) => _setRange(r),
                    ),
                  ),
              ],
            ),
          ),
          if (_historyLoading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTab(_Tab tab) {
    final List<Widget> children;
    switch (tab) {
      case _Tab.overview:
        children = _overview();
      case _Tab.cpu:
        children = _cpu();
      case _Tab.memory:
        children = _memory();
      case _Tab.disk:
        children = _disk();
      case _Tab.network:
        children = _network();
      case _Tab.sensors:
        children = _sensors();
      case _Tab.gpu:
        children = _gpu();
      case _Tab.containers:
        children = _containersTab();
      case _Tab.services:
        children = _servicesTab();
      case _Tab.smart:
        children = _smartTab();
    }
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          if (_error != null && tab.hasCharts)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ...children,
        ],
      ),
    );
  }

  // ------------------------------------------------------------- helpers

  ChartSeries _series(
    String label,
    Color color,
    double? Function(StatsPoint p) value, {
    bool fill = true,
    bool dashed = false,
  }) {
    return ChartSeries(
      label: label,
      color: color,
      fill: fill,
      dashed: dashed,
      points: [for (final p in _points) (p.time, value(p))],
    );
  }

  bool get _showMax => _range != ChartRange.live && _range != ChartRange.hour;

  String _pct(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)}%';

  Widget _chartCard(
    String title,
    List<ChartSeries> series, {
    required String Function(double) format,
    double? maxY,
    IconData? icon,
    String? subtitle,
  }) {
    return SectionCard(
      title: title,
      subtitle: subtitle,
      icon: icon,
      child: TimeSeriesChart(
        series: series,
        range: _range,
        formatValue: format,
        maxY: maxY,
      ),
    );
  }

  // ------------------------------------------------------------ overview

  List<Widget> _overview() {
    final s = _system;
    final d = _details;
    final latest = _latest;
    final la = s.loadAvg;
    final threads = d?.threads ?? s.threads;

    final info = <(String, String)>[
      (tr('hostname'), d?.hostname ?? s.hostname ?? ''),
      (tr('host'), s.port.isNotEmpty ? '${s.host}:${s.port}' : s.host),
      (tr('os'), d?.osName.isNotEmpty == true ? d!.osName : _osName(d?.os ?? s.os)),
      (tr('kernel'), d?.kernel ?? s.kernel ?? ''),
      (tr('cpu_model'), d?.cpu ?? s.cpuModel ?? ''),
      (
        '${tr('cores')} / ${tr('threads')}',
        '${d?.cores ?? s.cores} / $threads',
      ),
      if (d != null && d.arch.isNotEmpty) (tr('arch'), d.arch),
      if (d != null && d.memory > 0) (tr('memory'), formatBytes(d.memory)),
      (tr('uptime'), formatUptime(s.uptime)),
      (tr('agent_version'), s.agentVersion ?? '-'),
      if (s.connectionType > 0)
        (tr('connection'), s.connectionType == 2 ? 'WebSocket' : 'SSH'),
      if (d?.podman == true) ('Podman', '✓'),
    ];

    return [
      if (s.isPaused || s.isPending || s.isDown)
        Card(
          color: statusColor(s.status).withValues(alpha: 0.12),
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(Icons.info_outline, color: statusColor(s.status)),
            title: Text('status_${s.status}_hint'.tr()),
          ),
        ),
      SectionCard(
        title: tr('usage'),
        icon: Icons.speed,
        child: Column(
          children: [
            UsageBar(label: 'CPU', percent: s.cpuPercent, icon: Icons.memory),
            const SizedBox(height: 10),
            UsageBar(
              label: tr('ram'),
              percent: s.memoryPercent,
              icon: Icons.storage,
              detail: latest != null && latest.memTotal > 0
                  ? '${formatGB(latest.memUsed)} / ${formatGB(latest.memTotal)}'
                  : null,
            ),
            const SizedBox(height: 10),
            UsageBar(
              label: s.rootDiskName ?? tr('disk'),
              percent: s.diskPercent,
              icon: Icons.disc_full,
              detail: latest != null && latest.diskTotal > 0
                  ? '${formatGB(latest.diskUsed)} / ${formatGB(latest.diskTotal)}'
                  : null,
            ),
            for (final e in s.extraFs.entries) ...[
              const SizedBox(height: 10),
              UsageBar(label: e.key, percent: e.value, icon: Icons.disc_full),
            ],
            if (s.gpuPercent != null) ...[
              const SizedBox(height: 10),
              UsageBar(
                label: 'GPU',
                percent: s.gpuPercent!,
                icon: Icons.videogame_asset_outlined,
              ),
            ],
          ],
        ),
      ),
      SectionCard(
        title: tr('status'),
        icon: Icons.monitor_heart_outlined,
        child: KeyValueGrid(
          items: [
            (tr('network'), formatBytesRate(s.bandwidth)),
            if (la.isNotEmpty)
              (
                tr('load'),
                la.map((v) => v.toStringAsFixed(2)).join('  '),
              ),
            if (s.temperature != null) (tr('temperature'), formatTemp(s.temperature)),
            if (s.battery != null)
              (
                tr('battery'),
                '${s.battery!.$1}% · ${tr('battery_${s.battery!.$2.name}')}',
              ),
            if (s.services.isNotEmpty)
              (
                tr('services'),
                '${s.services[0]} · ${tr('failed')}: ${s.services[1]}',
              ),
            for (final w in s.wifi.entries)
              (
                'Wi-Fi ${w.key}',
                [
                  if (w.value.$1 != null) w.value.$1!,
                  if (w.value.$2 != null) '${w.value.$2!.toStringAsFixed(0)} dBm',
                ].join(' · '),
              ),
          ],
        ),
      ),
      if (s.pendingUpdates.isNotEmpty && s.pendingUpdates[0] > 0)
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const Icon(Icons.system_update_alt, color: Colors.orange),
            title: Text(
              tr('pending_updates', args: ['${s.pendingUpdates[0]}']),
            ),
            subtitle: s.pendingUpdates.length > 1
                ? Text(tr('security_updates', args: ['${s.pendingUpdates[1]}']))
                : null,
            trailing: const Icon(Icons.chevron_right),
            onTap: _showPackageUpdates,
          ),
        ),
      SectionCard(
        title: tr('system_info'),
        icon: Icons.info_outline,
        child: KeyValueGrid(items: info),
      ),
    ];
  }

  String _osName(SystemOs os) => switch (os) {
    SystemOs.linux => 'Linux',
    SystemOs.darwin => 'macOS',
    SystemOs.windows => 'Windows',
    SystemOs.freebsd => 'FreeBSD',
    SystemOs.unknown => '-',
  };

  Future<void> _showPackageUpdates() async {
    await showTextSheet(
      context,
      title: tr('pending_updates', args: ['${_system.pendingUpdates[0]}']),
      load: () async {
        final res = await _api.packageUpdates(_system.id);
        final packages = res['packages'];
        final buf = StringBuffer();
        if (res['manager'] != null) buf.writeln('${res['manager']}\n');
        if (packages is List) {
          for (final p in packages) {
            final m = asMap(p);
            final sec = m['security'] == true ? ' [security]' : '';
            buf.writeln(
              '${m['name']}  ${m['current'] ?? ''} → ${m['available'] ?? ''}$sec',
            );
          }
        }
        return buf.toString();
      },
    );
  }

  // ----------------------------------------------------------------- cpu

  List<Widget> _cpu() {
    final latest = _latest;
    final breakdown = latest?.cpuBreakdown ?? const [];
    final cores = latest?.cpuCores ?? const [];
    final hasLoad = _points.any((p) => p.loadAvg.length >= 3);
    final threads = _details?.threads ?? _system.threads;

    return [
      _chartCard(
        tr('cpu_usage'),
        [
          _series('CPU', Colors.blue, (p) => p.cpu),
          if (_showMax && _points.any((p) => p.cpuMax != null))
            _series(
              tr('max'),
              Colors.blue.shade200,
              (p) => p.cpuMax,
              fill: false,
              dashed: true,
            ),
        ],
        format: _pct,
        maxY: 100,
        icon: Icons.memory,
        subtitle: _details?.cpu ?? _system.cpuModel,
      ),
      if (breakdown.length >= 5)
        SectionCard(
          title: tr('cpu_breakdown'),
          icon: Icons.donut_small,
          child: Column(
            children: [
              for (final (i, name) in const [
                (0, 'user'),
                (1, 'system'),
                (2, 'iowait'),
                (3, 'steal'),
              ]) ...[
                UsageBar(label: tr('cpu_$name'), percent: breakdown[i]),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      if (hasLoad)
        _chartCard(
          tr('load_average'),
          [
            for (final (i, label, color) in [
              (0, '1m', Colors.blue),
              (1, '5m', Colors.orange),
              (2, '15m', Colors.purple),
            ])
              _series(
                label,
                color,
                (p) => p.loadAvg.length >= 3 ? p.loadAvg[i] : null,
                fill: false,
              ),
          ],
          format: (v) => v.toStringAsFixed(2),
          icon: Icons.speed,
          subtitle: threads > 0 ? '${tr('threads')}: $threads' : null,
        ),
      if (cores.isNotEmpty)
        SectionCard(
          title: tr('cpu_cores'),
          icon: Icons.grid_view,
          child: _coreGrid(cores),
        ),
    ];
  }

  Widget _coreGrid(List<double> cores) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = math.max(2, (c.maxWidth / 86).floor());
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            childAspectRatio: 2.1,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemCount: cores.length,
          itemBuilder: (context, index) {
            final usage = cores[index];
            final color = usageColor(usage);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('$index', style: const TextStyle(fontSize: 10)),
                      Text(
                        '${usage.toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (usage / 100).clamp(0.0, 1.0),
                      minHeight: 5,
                      color: color,
                      backgroundColor: Colors.grey.withValues(alpha: 0.2),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------- memory

  List<Widget> _memory() {
    final latest = _latest;
    final total = latest?.memTotal ?? 0;
    final hasSwap = _points.any((p) => p.swapTotal > 0);
    final hasArc = _points.any((p) => p.memZfsArc > 0);
    return [
      _chartCard(
        tr('memory_usage'),
        [
          _series(tr('used'), Colors.purple, (p) => p.memUsed),
          _series(
            tr('buff_cache'),
            Colors.teal,
            (p) => p.memBuffCache > 0 ? p.memBuffCache : null,
            fill: false,
          ),
          if (hasArc)
            _series('ZFS ARC', Colors.amber, (p) => p.memZfsArc, fill: false),
        ],
        format: formatGB,
        maxY: total > 0 ? total : null,
        icon: Icons.storage,
      ),
      if (latest != null)
        SectionCard(
          title: tr('ram'),
          icon: Icons.info_outline,
          child: KeyValueGrid(
            items: [
              (tr('total'), formatGB(latest.memTotal)),
              (tr('used'), formatGB(latest.memUsed)),
              (tr('buff_cache'), formatGB(latest.memBuffCache)),
              (tr('utilization'), formatPercent(latest.memPercent)),
              if (latest.memZfsArc > 0) ('ZFS ARC', formatGB(latest.memZfsArc)),
              if (latest.swapTotal > 0)
                (
                  'Swap',
                  '${formatGB(latest.swapUsed)} / ${formatGB(latest.swapTotal)}',
                ),
            ],
          ),
        ),
      if (hasSwap)
        _chartCard(
          tr('swap_usage'),
          [_series('Swap', Colors.deepOrange, (p) => p.swapUsed)],
          format: formatGB,
          maxY: latest != null && latest.swapTotal > 0 ? latest.swapTotal : null,
          icon: Icons.swap_horiz,
        ),
    ];
  }

  // ---------------------------------------------------------------- disk

  List<Widget> _disk() {
    final latest = _latest;
    final fsNames = <String>{
      for (final p in _points) ...p.extraFs.keys,
    }.toList()..sort();
    final pools = latest?.pools ?? const <String, StoragePool>{};
    final totals = latest?.diskIoTotal ?? const [];

    return [
      _chartCard(
        _system.rootDiskName ?? tr('root_disk'),
        [_series(tr('used'), Colors.orange, (p) => p.diskUsed)],
        format: formatGB,
        maxY: latest != null && latest.diskTotal > 0 ? latest.diskTotal : null,
        icon: Icons.disc_full,
        subtitle: latest != null
            ? '${formatGB(latest.diskUsed)} / ${formatGB(latest.diskTotal)} · ${formatPercent(latest.diskPercent)}'
            : null,
      ),
      _chartCard(
        tr('disk_io'),
        [
          _series(tr('read'), Colors.blue, (p) => p.diskIo[0]),
          _series(tr('write'), Colors.red, (p) => p.diskIo[1]),
        ],
        format: formatBytesRate,
        icon: Icons.sync_alt,
        subtitle: totals.length >= 2
            ? '${tr('total')}: ↓ ${formatBytes(totals[0])} · ↑ ${formatBytes(totals[1])}'
            : null,
      ),
      for (final name in fsNames) ..._extraFsCards(name),
      if (pools.isNotEmpty)
        SectionCard(
          title: tr('storage_pools'),
          icon: Icons.layers_outlined,
          child: Column(
            children: [
              for (final e in pools.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: UsageBar(
                    label:
                        '${e.value.name ?? e.key}${e.value.health != null ? ' · ${e.value.health}' : ''}',
                    percent: e.value.percent,
                    detail:
                        '${formatGB(e.value.used)} / ${formatGB(e.value.total)}',
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _extraFsCards(String name) {
    ExtraFs? last;
    for (final p in _points.reversed) {
      last = p.extraFs[name];
      if (last != null) break;
    }
    return [
      _chartCard(
        name,
        [_series(tr('used'), Colors.orange, (p) => p.extraFs[name]?.used)],
        format: formatGB,
        maxY: last != null && last.total > 0 ? last.total : null,
        icon: Icons.disc_full,
        subtitle: last != null
            ? '${formatGB(last.used)} / ${formatGB(last.total)} · ${formatPercent(last.percent)}'
            : null,
      ),
      _chartCard(
        '$name · ${tr('disk_io')}',
        [
          _series(tr('read'), Colors.blue, (p) => p.extraFs[name]?.readRate),
          _series(tr('write'), Colors.red, (p) => p.extraFs[name]?.writeRate),
        ],
        format: formatBytesRate,
        icon: Icons.sync_alt,
        subtitle: last?.totalRead != null
            ? '${tr('total')}: ↓ ${formatBytes(last!.totalRead)} · ↑ ${formatBytes(last.totalWrite)}'
            : null,
      ),
    ];
  }

  // ------------------------------------------------------------- network

  List<Widget> _network() {
    final latest = _latest;
    final ni = latest?.interfaces ?? const <String, List<double>>{};
    double totalUp = 0, totalDown = 0;
    for (final v in ni.values) {
      if (v.length >= 4) {
        totalUp += v[2];
        totalDown += v[3];
      }
    }
    return [
      _chartCard(
        tr('bandwidth'),
        [
          _series(tr('sent'), Colors.green, (p) => p.network[0]),
          _series(tr('received'), Colors.blue, (p) => p.network[1]),
        ],
        format: formatBytesRate,
        icon: Icons.swap_vert,
        subtitle: latest != null
            ? '↑ ${formatBytesRate(latest.network[0])}  ↓ ${formatBytesRate(latest.network[1])}'
            : null,
      ),
      if (ni.isNotEmpty)
        SectionCard(
          title: tr('interfaces'),
          icon: Icons.lan_outlined,
          subtitle:
              '${tr('total')}: ↑ ${formatBytes(totalUp)} · ↓ ${formatBytes(totalDown)}',
          child: Column(
            children: [
              for (final e in ni.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.settings_ethernet),
                  title: Text(e.key),
                  subtitle: e.value.length >= 4
                      ? Text(
                          '${tr('total')}: ↑ ${formatBytes(e.value[2])} · ↓ ${formatBytes(e.value[3])}',
                        )
                      : null,
                  trailing: e.value.length >= 2
                      ? Text(
                          '↑ ${formatBytesRate(e.value[0])}\n↓ ${formatBytesRate(e.value[1])}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12),
                        )
                      : null,
                ),
            ],
          ),
        ),
    ];
  }

  // ------------------------------------------------------------- sensors

  List<Widget> _sensors() {
    final latest = _latest;
    final temps = latest?.temperatures ?? const <String, double>{};
    final sorted = temps.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final chartSensors = sorted.take(8).map((e) => e.key).toList();
    final fans = latest?.fans ?? const <String, double>{};
    final batteries = latest?.batteries ?? const <String, double>{};
    final battery = _system.battery;

    return [
      if (chartSensors.isNotEmpty)
        _chartCard(
          tr('temperature'),
          [
            for (var i = 0; i < chartSensors.length; i++)
              _series(
                chartSensors[i],
                chartPalette[i % chartPalette.length],
                (p) => p.temperatures[chartSensors[i]],
                fill: false,
              ),
          ],
          format: (v) => '${v.toStringAsFixed(0)}°',
          icon: Icons.thermostat,
        ),
      if (sorted.isNotEmpty)
        SectionCard(
          title: tr('sensors'),
          icon: Icons.sensors,
          child: Column(
            children: [
              for (final e in sorted)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(e.key, style: const TextStyle(fontSize: 13))),
                      Text(
                        formatTemp(e.value),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: tempColor(e.value),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      if (fans.isNotEmpty)
        SectionCard(
          title: tr('fans'),
          icon: Icons.wind_power,
          child: KeyValueGrid(
            items: [
              for (final e in fans.entries)
                (e.key, '${e.value.toStringAsFixed(0)} RPM'),
            ],
          ),
        ),
      if (battery != null || batteries.isNotEmpty)
        SectionCard(
          title: tr('battery'),
          icon: Icons.battery_std,
          child: Column(
            children: [
              if (battery != null)
                UsageBar(
                  label: tr('battery_${battery.$2.name}'),
                  percent: battery.$1.toDouble(),
                ),
              for (final e in batteries.entries) ...[
                const SizedBox(height: 8),
                UsageBar(label: e.key, percent: e.value),
              ],
            ],
          ),
        ),
    ];
  }

  // ----------------------------------------------------------------- gpu

  List<Widget> _gpu() {
    final ids = <String>{for (final p in _points) ...p.gpus.keys}.toList()
      ..sort();
    if (ids.isEmpty) {
      return [
        SectionCard(
          title: 'GPU',
          icon: Icons.videogame_asset_outlined,
          child: UsageBar(label: 'GPU', percent: _system.gpuPercent ?? 0),
        ),
      ];
    }
    final widgets = <Widget>[];
    for (final id in ids) {
      Gpu? last;
      for (final p in _points.reversed) {
        last = p.gpus[id];
        if (last != null) break;
      }
      final name = last?.name ?? id;
      widgets.add(
        _chartCard(
          name,
          [_series(tr('utilization'), Colors.green, (p) => p.gpus[id]?.usage)],
          format: _pct,
          maxY: 100,
          icon: Icons.videogame_asset_outlined,
          subtitle: last != null ? formatPercent(last.usage) : null,
        ),
      );
      if (_points.any((p) => p.gpus[id]?.memUsed != null)) {
        widgets.add(
          _chartCard(
            '$name · ${tr('vram')}',
            [_series(tr('used'), Colors.purple, (p) => p.gpus[id]?.memUsed)],
            format: formatMB,
            maxY: last?.memTotal,
            icon: Icons.memory,
            subtitle: last?.memUsed != null
                ? '${formatMB(last!.memUsed)} / ${formatMB(last.memTotal)}'
                : null,
          ),
        );
      }
      if (_points.any((p) => p.gpus[id]?.power != null)) {
        widgets.add(
          _chartCard(
            '$name · ${tr('power')}',
            [
              _series(tr('power'), Colors.amber, (p) => p.gpus[id]?.power),
              if (_points.any((p) => p.gpus[id]?.packagePower != null))
                _series(
                  tr('package_power'),
                  Colors.deepOrange,
                  (p) => p.gpus[id]?.packagePower,
                  fill: false,
                ),
            ],
            format: (v) => '${v.toStringAsFixed(1)} W',
            icon: Icons.bolt,
          ),
        );
      }
      if (last != null && last.engines.isNotEmpty) {
        widgets.add(
          SectionCard(
            title: '$name · ${tr('engines')}',
            icon: Icons.settings_input_component,
            child: Column(
              children: [
                for (final e in last.engines.entries) ...[
                  UsageBar(label: e.key, percent: e.value),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        );
      }
    }
    return widgets;
  }

  // ---------------------------------------------------------- containers

  List<Widget> _containersTab() {
    final running = _containers.where((c) => c.isRunning).length;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          tr('containers_summary', args: ['${_containers.length}', '$running']),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      for (final c in _containers)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _showContainer(c),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 10,
                        color: _healthColor(c),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (c.updatable)
                        Pill(
                          text: tr('update_available'),
                          color: Colors.blue,
                          icon: Icons.upgrade,
                        ),
                      if (c.health == 3) ...[
                        const SizedBox(width: 4),
                        Pill(text: tr('unhealthy'), color: Colors.red),
                      ],
                    ],
                  ),
                  if (c.image.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 18),
                      child: Text(
                        c.image,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      _miniStat(Icons.memory, formatPercent(c.cpu)),
                      _miniStat(Icons.storage, formatMB(c.memory)),
                      _miniStat(Icons.swap_vert, formatBytesRate(c.net)),
                      _miniStat(Icons.schedule, c.status),
                      if (c.ports.isNotEmpty)
                        _miniStat(Icons.settings_ethernet, c.ports),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  Color _healthColor(ContainerInfo c) {
    if (!c.isRunning) return Colors.grey;
    switch (c.health) {
      case 3:
        return Colors.red;
      case 1:
        return Colors.amber;
      default:
        return Colors.green;
    }
  }

  Widget _miniStat(IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: Colors.grey),
      const SizedBox(width: 3),
      Text(text, style: const TextStyle(fontSize: 12)),
    ],
  );

  void _showContainer(ContainerInfo c) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(c.image),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(tr('logs')),
              onTap: () {
                Navigator.pop(ctx);
                showTextSheet(
                  context,
                  title: '${c.name} · ${tr('logs')}',
                  load: () => _api.containerLogs(_system.id, c.id),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.data_object),
              title: Text(tr('details')),
              onTap: () {
                Navigator.pop(ctx);
                showTextSheet(
                  context,
                  title: c.name,
                  load: () => _api.containerInfo(_system.id, c.id),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ services

  List<Widget> _servicesTab() {
    final failed = _services.where((s) => s.isFailed).length;
    final q = _serviceFilter.toLowerCase();
    final filtered = q.isEmpty
        ? _services
        : _services.where((s) => s.name.toLowerCase().contains(q)).toList();
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              tr('services_summary', args: ['${_services.length}', '$failed']),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextField(
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: tr('search'),
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => _serviceFilter = v),
      ),
      const SizedBox(height: 8),
      for (final s in filtered)
        Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: s.isFailed
                  ? Colors.red
                  : (s.state == 0 ? Colors.green : Colors.grey),
            ),
            title: Text(s.name, overflow: TextOverflow.ellipsis),
            subtitle: Text('${s.stateName} (${s.subName})'),
            trailing: Text(
              'CPU ${formatPercent(s.cpu)}\n${formatBytes(s.memory)}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11),
            ),
            onTap: _system.journalAvailable
                ? () => showTextSheet(
                    context,
                    title: '${s.name} · ${tr('logs')}',
                    load: () => _api.serviceLogs(_system.id, s.name),
                  )
                : null,
          ),
        ),
    ];
  }

  // --------------------------------------------------------------- smart

  Future<void> _refreshSmart() async {
    setState(() => _smartRefreshing = true);
    try {
      await _api.refreshSmart(_system.id);
      await Future.delayed(const Duration(seconds: 2));
      await _loadSmart();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _smartRefreshing = false);
    }
  }

  Color _smartColor(SmartDevice d) {
    if (d.passed) return Colors.green;
    if (d.failed) return Colors.red;
    if (d.state.toUpperCase() == 'WARNING') return Colors.orange;
    return Colors.grey;
  }

  List<Widget> _smartTab() {
    return [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _smartRefreshing ? null : _refreshSmart,
          icon: _smartRefreshing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: Text(tr('refresh')),
        ),
      ),
      for (final d in _smart)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _showSmart(d),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.save_outlined, color: _smartColor(d)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.name,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              d.model,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Pill(
                        text: d.state.isEmpty ? 'UNKNOWN' : d.state,
                        color: _smartColor(d),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      if (d.temp != null && d.temp! > 0)
                        _miniStat(Icons.thermostat, formatTemp(d.temp)),
                      if (d.capacity > 0)
                        _miniStat(Icons.sd_storage, formatBytes(d.capacity, decimals: 1)),
                      _miniStat(Icons.timer_outlined, '${d.hours} h'),
                      _miniStat(Icons.power_settings_new, '${d.cycles}'),
                      if (d.type.isNotEmpty) _miniStat(Icons.cable, d.type.toUpperCase()),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  void _showSmart(SmartDevice device) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (ctx, controller) => FutureBuilder<RecordModel>(
          future: PocketBaseService().pb
              .collection('smart_devices')
              .getOne(device.id),
          builder: (ctx, snap) {
            final d = snap.hasData
                ? SmartDevice.fromRecord(snap.data!)
                : device;
            return ListView(
              controller: controller,
              padding: const EdgeInsets.all(16),
              children: [
                Text(d.name, style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                KeyValueGrid(
                  items: [
                    (tr('model'), d.model),
                    (tr('serial'), d.serial),
                    (tr('firmware'), d.firmware),
                    (tr('capacity'), formatBytes(d.capacity, decimals: 1)),
                    (tr('status'), d.state),
                    (tr('temperature'), d.temp != null ? formatTemp(d.temp) : '-'),
                    (tr('power_on_hours'), '${d.hours}'),
                    (tr('power_cycles'), '${d.cycles}'),
                  ],
                ),
                const SizedBox(height: 16),
                if (snap.connectionState != ConnectionState.done)
                  const Center(child: CircularProgressIndicator())
                else if (d.attributes.isEmpty)
                  Text(tr('no_data'))
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columnSpacing: 14,
                      headingRowHeight: 32,
                      dataRowMinHeight: 28,
                      dataRowMaxHeight: 36,
                      columns: [
                        const DataColumn(label: Text('ID')),
                        DataColumn(label: Text(tr('attribute'))),
                        DataColumn(label: Text(tr('value')), numeric: true),
                        DataColumn(label: Text(tr('worst')), numeric: true),
                        DataColumn(label: Text(tr('threshold')), numeric: true),
                        DataColumn(label: Text(tr('raw'))),
                      ],
                      rows: [
                        for (final a in d.attributes)
                          DataRow(
                            color: a.whenFailed != null
                                ? WidgetStatePropertyAll(
                                    Colors.red.withValues(alpha: 0.12),
                                  )
                                : null,
                            cells: [
                              DataCell(Text(a.id?.toString() ?? '')),
                              DataCell(Text(a.name)),
                              DataCell(Text(a.value?.toString() ?? '')),
                              DataCell(Text(a.worst?.toString() ?? '')),
                              DataCell(Text(a.threshold?.toString() ?? '')),
                              DataCell(Text(a.rawValue)),
                            ],
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
