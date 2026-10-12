import 'dart:async';
import 'dart:convert';

import 'package:pocketbase/pocketbase.dart';
import 'package:beszel_pro/models/records.dart';
import 'package:beszel_pro/models/stats.dart';
import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:beszel_pro/utils/format.dart';

/// Thin wrapper around the Beszel hub collections / custom routes.
class BeszelApi {
  PocketBase get _pb => PocketBaseService().pb;

  static const _freshnessMs = 70 * 1000;

  Future<List<System>> fetchSystems() async {
    final records = await _pb
        .collection('systems')
        .getFullList(sort: '+name', fields: 'id,name,host,port,info,status,updated');
    return records.map(System.fromRecord).toList();
  }

  /// Static system information. Old agents keep it in `info` instead.
  Future<SystemDetails?> fetchDetails(System system) async {
    if (system.hasLegacyDetails) return SystemDetails.fromLegacyInfo(system);
    try {
      final r = await _pb.collection('system_details').getOne(system.id);
      return SystemDetails.fromRecord(r);
    } catch (_) {
      return null;
    }
  }

  /// History for [range] (not [ChartRange.live]).
  Future<List<StatsPoint>> fetchStats(
    String systemId,
    ChartRange range, {
    String collection = 'system_stats',
  }) async {
    final since = DateTime.now().subtract(range.span);
    final records = await _pb
        .collection(collection)
        .getFullList(
          filter: _pb.filter(
            'system={:id} && created > {:created} && type={:type}',
            {'id': systemId, 'created': pbTimestamp(since), 'type': range.type},
          ),
          fields: 'created,stats',
          sort: 'created',
        );
    final points = <StatsPoint>[];
    for (final r in records) {
      final time = parsePbDate(r.data['created']);
      if (time == null) continue;
      points.add(StatsPoint(time, asMap(r.data['stats'])));
    }
    return points;
  }

  /// Latest container_stats entries for [range]: list of (time, containers).
  Future<List<(DateTime, List<Map<String, dynamic>>)>> fetchContainerStats(
    String systemId,
    ChartRange range,
  ) async {
    final since = DateTime.now().subtract(range.span);
    final records = await _pb
        .collection('container_stats')
        .getFullList(
          filter: _pb.filter(
            'system={:id} && created > {:created} && type={:type}',
            {'id': systemId, 'created': pbTimestamp(since), 'type': range.type},
          ),
          fields: 'created,stats',
          sort: 'created',
        );
    final result = <(DateTime, List<Map<String, dynamic>>)>[];
    for (final r in records) {
      final time = parsePbDate(r.data['created']);
      final stats = r.data['stats'];
      if (time == null || stats is! List) continue;
      result.add((time, stats.map(asMap).toList()));
    }
    return result;
  }

  Future<List<ContainerInfo>> fetchContainers(String systemId) async {
    final res = await _pb
        .collection('containers')
        .getList(
          page: 1,
          perPage: 2000,
          filter: _pb.filter('system={:system}', {'system': systemId}),
          fields:
              'id,name,image,updatable,ports,cpu,memory,net,health,status,system,updated',
        );
    final items = res.items.map(ContainerInfo.fromRecord).toList();
    return _fresh(items, (c) => c.updated)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<List<SystemdService>> fetchServices(String systemId) async {
    final records = await _pb
        .collection('systemd_services')
        .getFullList(
          filter: _pb.filter('system={:system}', {'system': systemId}),
          fields: 'id,name,state,sub,cpu,cpuPeak,memory,memPeak,updated',
        );
    final items = records.map(SystemdService.fromRecord).toList();
    return _fresh(items, (s) => s.updated)..sort((a, b) {
      if (a.isFailed != b.isFailed) return a.isFailed ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// Only keep rows reported within 70 s of the newest one (like the web UI).
  List<T> _fresh<T>(List<T> items, int Function(T) updated) {
    if (items.isEmpty) return items;
    final newest = items.map(updated).reduce((a, b) => a > b ? a : b);
    return items.where((i) => newest - updated(i) <= _freshnessMs).toList();
  }

  Future<List<SmartDevice>> fetchSmartDevices(String systemId) async {
    final records = await _pb
        .collection('smart_devices')
        .getFullList(
          filter: _pb.filter('system={:system}', {'system': systemId}),
          sort: 'name',
        );
    return records.map(SmartDevice.fromRecord).toList();
  }

  Future<void> refreshSmart(String systemId) async {
    await _pb.send(
      '/api/beszel/smart/refresh',
      method: 'POST',
      query: {'system': systemId},
    );
  }

  Future<String> containerLogs(String systemId, String containerId) async {
    final res = await _pb.send<Map<String, dynamic>>(
      '/api/beszel/containers/logs',
      query: {'system': systemId, 'container': containerId},
    );
    return res['logs']?.toString() ?? '';
  }

  Future<String> containerInfo(String systemId, String containerId) async {
    final res = await _pb.send<Map<String, dynamic>>(
      '/api/beszel/containers/info',
      query: {'system': systemId, 'container': containerId},
    );
    final info = res['info'];
    if (info is String) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(info));
      } catch (_) {
        return info;
      }
    }
    return const JsonEncoder.withIndent('  ').convert(info);
  }

  Future<String> serviceLogs(String systemId, String service) async {
    final res = await _pb.send<Map<String, dynamic>>(
      '/api/beszel/systemd/logs',
      query: {'system': systemId, 'service': service},
    );
    return res['logs']?.toString() ?? '';
  }

  Future<Map<String, dynamic>> packageUpdates(String systemId) async {
    return await _pb.send<Map<String, dynamic>>(
      '/api/beszel/package-updates',
      query: {'system': systemId},
    );
  }

  Future<List<HubAlertEvent>> fetchAlertHistory({int perPage = 200}) async {
    final res = await _pb
        .collection('alerts_history')
        .getList(
          page: 1,
          perPage: perPage,
          expand: 'system',
          fields:
              'id,name,monitor_name,value,system,created,resolved,expand.system.name',
          sort: '-created',
        );
    return res.items.map(HubAlertEvent.fromRecord).toList();
  }

  Future<void> deleteAlertHistory(String id) =>
      _pb.collection('alerts_history').delete(id);

  Future<List<HubAlertRule>> fetchAlertRules() async {
    final records = await _pb
        .collection('alerts')
        .getFullList(fields: 'id,name,system,value,min,triggered', sort: 'updated');
    return records.map(HubAlertRule.fromRecord).toList();
  }

  /// Hub version info: `{key, v, cu}`.
  Future<Map<String, dynamic>> hubInfo() =>
      _pb.send<Map<String, dynamic>>('/api/beszel/info');

  /// Live metrics (~1/s) pushed by the hub for one system.
  /// Each event contains `{stats, info, container}`.
  Future<UnsubscribeFunc> subscribeLive(
    String systemId,
    void Function(Map<String, dynamic> data) onData,
  ) {
    return _pb.realtime.subscribe('rt_metrics', (e) {
      final raw = e.data;
      if (raw.isEmpty) return;
      try {
        onData(asMap(jsonDecode(raw)));
      } catch (_) {}
    }, query: {'system': systemId});
  }
}
