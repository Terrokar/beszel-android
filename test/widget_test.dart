import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:beszel_pro/models/stats.dart';
import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/utils/format.dart';

void main() {
  group('format', () {
    test('formatBytes uses binary units', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.50 KB');
      expect(formatGB(1), '1.00 GB');
      expect(formatMB(512), '512.0 MB');
    });

    test('versionAtLeast compares semver', () {
      expect(versionAtLeast('0.21.0', '0.13.0'), isTrue);
      expect(versionAtLeast('0.12.9', '0.13.0'), isFalse);
      expect(versionAtLeast('v0.15.3-beta', '0.15.3'), isTrue);
      expect(versionAtLeast(null, '0.1.0'), isFalse);
    });

    test('pbTimestamp is UTC in PocketBase format', () {
      final t = DateTime.utc(2026, 1, 2, 3, 4, 5);
      expect(pbTimestamp(t), '2026-01-02 03:04:05');
    });
  });

  group('System', () {
    RecordModel record(Map<String, dynamic> info, {String status = 'up'}) =>
        RecordModel.fromJson({
          'id': 'abc',
          'name': 'srv',
          'host': '10.0.0.2',
          'port': '45876',
          'status': status,
          'info': info,
        });

    test('parses current agent info keys', () {
      final s = System.fromRecord(
        record({
          'cpu': 12.5,
          'mp': 40,
          'dp': 70.2,
          'bb': 2048,
          'u': 3600,
          'v': '0.21.0',
          'os': 2,
          'la': [0.5, 0.4, 0.3],
          'g': 33.0,
          'dt': 55.5,
          'efs': {'nvme1': 12.0, 'sdb1': 80.5},
          'sv': [42, 1],
          'bat': [80, 4],
          'pu': [5, 2],
          'wf': {
            'wlan0': {'s': 'home', 'r': -51},
          },
        }),
      );
      expect(s.cpuPercent, 12.5);
      expect(s.bandwidth, 2048);
      expect(s.os, SystemOs.windows);
      expect(s.loadAvg, [0.5, 0.4, 0.3]);
      expect(s.gpuPercent, 33.0);
      expect(s.temperature, 55.5);
      expect(s.extraFs, {'nvme1': 12.0, 'sdb1': 80.5});
      expect(s.services, [42, 1]);
      expect(s.battery, (80, BatteryState.discharging));
      expect(s.pendingUpdates, [5, 2]);
      expect(s.wifi['wlan0'], ('home', -51.0));
      expect(s.hasLegacyDetails, isFalse);
    });

    test('handles paused systems with minimal info', () {
      final s = System.fromRecord(record({'v': '0.20.0'}, status: 'paused'));
      expect(s.isPaused, isTrue);
      expect(s.cpuPercent, 0);
      expect(s.gpuPercent, isNull);
      expect(s.battery, isNull);
      expect(s.extraFs, isEmpty);
    });

    test('legacy bandwidth is MB/s', () {
      final s = System.fromRecord(record({'b': 1.0, 'k': 'Darwin 23'}));
      expect(s.bandwidth, 1024 * 1024);
      expect(s.os, SystemOs.darwin);
    });
  });

  group('StatsPoint', () {
    test('prefers byte based keys and falls back to MB/s', () {
      final modern = StatsPoint(DateTime.now(), {
        'b': [100, 200],
        'dio': [10, 20],
      });
      expect(modern.network, [100.0, 200.0]);
      expect(modern.diskIo, [10.0, 20.0]);

      final legacy = StatsPoint(DateTime.now(), {
        'ns': 1,
        'nr': 2,
        'dr': 1,
        'dw': 0.5,
      });
      expect(legacy.network, [1048576.0, 2097152.0]);
      expect(legacy.diskIo, [1048576.0, 524288.0]);
    });

    test('parses extra filesystems, GPUs and temperatures', () {
      final p = StatsPoint(DateTime.now(), {
        'efs': {
          'data': {'d': 100, 'du': 25, 'rb': 5, 'wb': 6, 'tr': 1, 'tw': 2},
        },
        'g': {
          '0': {'n': 'RTX', 'u': 50, 'mu': 1024, 'mt': 8192, 'p': 120},
        },
        't': {'cpu': 60, 'nvme': 40},
      });
      expect(p.extraFs['data']!.percent, 25);
      expect(p.extraFs['data']!.readRate, 5);
      expect(p.gpus['0']!.name, 'RTX');
      expect(p.gpus['0']!.memTotal, 8192);
      expect(p.temperatures['cpu'], 60);
    });

    test('chart ranges map to Beszel stat types', () {
      expect(ChartRange.hour.type, '1m');
      expect(ChartRange.halfDay.type, '10m');
      expect(ChartRange.day.type, '20m');
      expect(ChartRange.week.type, '120m');
      expect(ChartRange.month.type, '480m');
      expect(ChartRange.fromLabel('nope'), ChartRange.hour);
    });
  });

  test('all translation files have the same keys', () {
    final dir = Directory('assets/translations');
    final files = dir.listSync().whereType<File>().toList();
    final en = (jsonDecode(File('${dir.path}/en.json').readAsStringSync())
            as Map)
        .keys
        .toSet();
    for (final f in files) {
      final keys = (jsonDecode(f.readAsStringSync()) as Map).keys.toSet();
      expect(keys, en, reason: f.path);
    }
  });
}
