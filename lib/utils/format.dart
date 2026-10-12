import 'package:flutter/material.dart';

/// Shared number / unit helpers that mirror the Beszel web UI.

double toDouble(dynamic val) {
  if (val is num) return val.toDouble();
  if (val is String) return double.tryParse(val) ?? 0.0;
  return 0.0;
}

double? toDoubleOrNull(dynamic val) {
  if (val is num) return val.toDouble();
  if (val is String) return double.tryParse(val);
  return null;
}

int toInt(dynamic val) {
  if (val is num) return val.toInt();
  if (val is String) return int.tryParse(val) ?? 0;
  return 0;
}

Map<String, dynamic> asMap(dynamic val) {
  if (val is Map<String, dynamic>) return val;
  if (val is Map) return val.map((k, v) => MapEntry(k.toString(), v));
  return <String, dynamic>{};
}

List<double> asDoubleList(dynamic val) {
  if (val is List) return val.map(toDouble).toList();
  return const [];
}

const _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// Formats a byte count using binary (1024) multiples like Beszel.
String formatBytes(num? bytes, {int decimals = 2}) {
  var value = (bytes ?? 0).toDouble();
  if (value <= 0 || value.isNaN) return '0 B';
  var i = 0;
  while (value >= 1024 && i < _units.length - 1) {
    value /= 1024;
    i++;
  }
  final d = i == 0 ? 0 : (value >= 100 ? 1 : decimals);
  return '${value.toStringAsFixed(d)} ${_units[i]}';
}

String formatBytesRate(num? bytesPerSec) => '${formatBytes(bytesPerSec)}/s';

/// Formats gigabytes (Beszel stores memory / disk sizes in GB).
String formatGB(num? gb) => formatBytes((gb ?? 0) * 1024 * 1024 * 1024);

/// Formats megabytes (container / GPU memory).
String formatMB(num? mb) => formatBytes((mb ?? 0) * 1024 * 1024);

String formatPercent(num? value, {int decimals = 1}) =>
    '${(value ?? 0).toStringAsFixed(decimals)}%';

String formatUptime(num? secondsNum) {
  final seconds = (secondsNum ?? 0).toInt();
  if (seconds <= 0) return '-';
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final mins = (seconds % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${mins}m';
  return '${mins}m';
}

String formatTemp(num? celsius) =>
    celsius == null ? '-' : '${celsius.toStringAsFixed(1)} °C';

/// Beszel default thresholds (Settings → warning 65%, critical 90%).
const double usageWarn = 65;
const double usageCrit = 90;

Color usageColor(num? value) {
  final v = (value ?? 0).toDouble();
  if (v >= usageCrit) return Colors.red;
  if (v >= usageWarn) return Colors.orange;
  return Colors.green;
}

Color tempColor(num? celsius) {
  final v = (celsius ?? 0).toDouble();
  if (v >= 85) return Colors.red;
  if (v >= 70) return Colors.orange;
  return Colors.green;
}

/// Parses a semantic version string like "0.21.0" into comparable parts.
List<int> parseSemVer(String? v) {
  if (v == null || v.isEmpty) return const [0, 0, 0];
  final clean = v.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[-+]')).first;
  final parts = clean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts.take(3).toList();
}

bool versionAtLeast(String? version, String min) {
  final a = parseSemVer(version);
  final b = parseSemVer(min);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return true;
}

/// PocketBase datetime ("2026-01-02 03:04:05.678Z") → local DateTime.
DateTime? parsePbDate(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value.replaceFirst(' ', 'T'))?.toLocal();
  }
  return null;
}

/// UTC timestamp in the format PocketBase filters expect.
String pbTimestamp(DateTime time) {
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
