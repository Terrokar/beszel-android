import 'package:beszel_pro/utils/format.dart';

/// Chart time ranges, mirroring `chartTimeData` of the Beszel web UI.
enum ChartRange {
  live('1m', '1m', Duration(minutes: 1), Duration(seconds: 2)),
  hour('1h', '1m', Duration(hours: 1), Duration(minutes: 1)),
  halfDay('12h', '10m', Duration(hours: 12), Duration(minutes: 10)),
  day('24h', '20m', Duration(hours: 24), Duration(minutes: 20)),
  week('1w', '120m', Duration(days: 7), Duration(hours: 2)),
  month('30d', '480m', Duration(days: 30), Duration(hours: 8));

  final String label;

  /// `system_stats.type` / `container_stats.type` to query.
  final String type;
  final Duration span;
  final Duration expectedInterval;

  const ChartRange(this.label, this.type, this.span, this.expectedInterval);

  static ChartRange fromLabel(String? label) => ChartRange.values.firstWhere(
    (r) => r.label == label,
    orElse: () => ChartRange.hour,
  );
}

/// One `system_stats` record (or one realtime sample).
class StatsPoint {
  final DateTime time;
  final Map<String, dynamic> stats;

  StatsPoint(this.time, this.stats);

  double get cpu => toDouble(stats['cpu']);
  double? get cpuMax => toDoubleOrNull(stats['cpum']);

  /// [user, system, iowait, steal, idle]
  List<double> get cpuBreakdown => asDoubleList(stats['cpub']);
  List<double> get cpuCores => asDoubleList(stats['cpus']);
  List<double> get loadAvg => asDoubleList(stats['la']);

  double get memTotal => toDouble(stats['m']); // GB
  double get memUsed => toDouble(stats['mu']); // GB
  double get memPercent => toDouble(stats['mp']);
  double get memBuffCache => toDouble(stats['mb']); // GB
  double get memZfsArc => toDouble(stats['mz']); // GB
  double get swapTotal => toDouble(stats['s']); // GB
  double get swapUsed => toDouble(stats['su']); // GB

  double get diskTotal => toDouble(stats['d']); // GB
  double get diskUsed => toDouble(stats['du']); // GB
  double get diskPercent => toDouble(stats['dp']);

  /// Disk I/O [read, write] in bytes/s (falls back to deprecated MB/s keys).
  List<double> get diskIo {
    final dio = asDoubleList(stats['dio']);
    if (dio.length >= 2) return dio;
    return [
      toDouble(stats['dr']) * 1024 * 1024,
      toDouble(stats['dw']) * 1024 * 1024,
    ];
  }

  /// Cumulative disk [read, write] bytes.
  List<double> get diskIoTotal => asDoubleList(stats['diot']);

  /// Network [sent, recv] in bytes/s (falls back to deprecated MB/s keys).
  List<double> get network {
    final b = asDoubleList(stats['b']);
    if (b.length >= 2) return b;
    return [
      toDouble(stats['ns']) * 1024 * 1024,
      toDouble(stats['nr']) * 1024 * 1024,
    ];
  }

  /// iface -> [up B/s, down B/s, total up bytes, total down bytes]
  Map<String, List<double>> get interfaces =>
      asMap(stats['ni']).map((k, v) => MapEntry(k, asDoubleList(v)));

  Map<String, double> get temperatures =>
      asMap(stats['t']).map((k, v) => MapEntry(k, toDouble(v)));

  Map<String, double> get fans =>
      asMap(stats['f']).map((k, v) => MapEntry(k, toDouble(v)));

  Map<String, ExtraFs> get extraFs =>
      asMap(stats['efs']).map((k, v) => MapEntry(k, ExtraFs(asMap(v))));

  Map<String, Gpu> get gpus =>
      asMap(stats['g']).map((k, v) => MapEntry(k, Gpu(asMap(v))));

  Map<String, StoragePool> get pools =>
      asMap(stats['z']).map((k, v) => MapEntry(k, StoragePool(asMap(v))));

  Map<String, double> get batteries =>
      asMap(stats['bats']).map((k, v) => MapEntry(k, toDouble(v)));
}

class ExtraFs {
  final Map<String, dynamic> raw;
  ExtraFs(this.raw);

  double get total => toDouble(raw['d']); // GB
  double get used => toDouble(raw['du']); // GB
  double get percent => total > 0 ? used / total * 100 : 0;

  double get readRate =>
      raw['rb'] is num ? toDouble(raw['rb']) : toDouble(raw['r']) * 1048576;
  double get writeRate =>
      raw['wb'] is num ? toDouble(raw['wb']) : toDouble(raw['w']) * 1048576;
  double? get totalRead => toDoubleOrNull(raw['tr']);
  double? get totalWrite => toDoubleOrNull(raw['tw']);
}

class Gpu {
  final Map<String, dynamic> raw;
  Gpu(this.raw);

  String get name => (raw['n'] as String?) ?? 'GPU';
  double get usage => toDouble(raw['u']);
  double? get memUsed => toDoubleOrNull(raw['mu']); // MB
  double? get memTotal => toDoubleOrNull(raw['mt']); // MB
  double? get power => toDoubleOrNull(raw['p']); // W
  double? get packagePower => toDoubleOrNull(raw['pp']); // W
  Map<String, double> get engines =>
      asMap(raw['e']).map((k, v) => MapEntry(k, toDouble(v)));
}

class StoragePool {
  final Map<String, dynamic> raw;
  StoragePool(this.raw);

  String? get name => raw['n'] as String?;
  double get total => toDouble(raw['d']); // GiB
  double get used => toDouble(raw['du']); // GiB
  double get percent => total > 0 ? used / total * 100 : 0;
  String? get health => raw['h'] as String?;
  bool get hideUsage => raw['hu'] == true;
}
