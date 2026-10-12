import 'package:pocketbase/pocketbase.dart';
import 'package:beszel_pro/utils/format.dart';

/// Operating system enum used by Beszel (`info.os` / `system_details.os`).
enum SystemOs { linux, darwin, windows, freebsd, unknown }

SystemOs systemOsFromValue(dynamic value) {
  switch (value) {
    case 0:
      return SystemOs.linux;
    case 1:
      return SystemOs.darwin;
    case 2:
      return SystemOs.windows;
    case 3:
      return SystemOs.freebsd;
  }
  return SystemOs.unknown;
}

/// Battery state enum (`info.bat[1]`).
enum BatteryState { unknown, empty, full, charging, discharging, idle }

class System {
  final String id;
  final String name;
  final String host;
  final String port;

  /// One of `up`, `down`, `paused`, `pending`.
  final String status;
  final String updated;
  final Map<String, dynamic> info;

  System({
    required this.id,
    required this.name,
    required this.host,
    this.port = '',
    required this.status,
    required this.updated,
    required this.info,
  });

  factory System.fromRecord(RecordModel record) {
    return System(
      id: record.id,
      name: record.getStringValue('name'),
      host: record.getStringValue('host'),
      port: record.getStringValue('port'),
      status: record.getStringValue('status'),
      updated: record.getStringValue('updated'),
      info: asMap(record.data['info']),
    );
  }

  bool get isUp => status == 'up';
  bool get isDown => status == 'down';
  bool get isPaused => status == 'paused';
  bool get isPending => status == 'pending';

  double get cpuPercent => toDouble(info['cpu']);
  double get memoryPercent => toDouble(info['mp']);
  double get diskPercent => toDouble(info['dp']);

  /// Combined network bandwidth in bytes/s (`bb`), falling back to the
  /// deprecated MB/s value (`b`) of older agents.
  double get bandwidth {
    if (info['bb'] is num) return toDouble(info['bb']);
    if (info['b'] is num) return toDouble(info['b']) * 1024 * 1024;
    return 0;
  }

  int get uptime => toInt(info['u']);
  int get threads => toInt(info['t']);
  int get cores => toInt(info['c']);
  String? get cpuModel => info['m'] as String?;
  String? get hostname => info['h'] as String?;
  String? get kernel => info['k'] as String?;
  String? get agentVersion {
    final v = info['v'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// True when the hub has never received data from the agent.
  bool get hasNoData => agentVersion == null && uptime == 0 && cpuPercent == 0;

  /// Old agents (< 0.15) keep the static details in `info`.
  bool get hasLegacyDetails => info['m'] != null;

  /// Operating system. Old agents only report the kernel string.
  SystemOs get os {
    if (info['os'] != null) return systemOsFromValue(toInt(info['os']));
    final k = kernel?.toLowerCase() ?? '';
    if (k.contains('windows')) return SystemOs.windows;
    if (k.contains('darwin')) return SystemOs.darwin;
    if (k.contains('freebsd')) return SystemOs.freebsd;
    return SystemOs.linux;
  }

  /// Load average [1m, 5m, 15m].
  List<double> get loadAvg {
    final la = asDoubleList(info['la']);
    if (la.length < 3 || la.every((v) => v == 0)) return const [];
    return la;
  }

  /// Highest GPU utilisation (null when the system has no GPU).
  double? get gpuPercent => toDoubleOrNull(info['g']);

  /// Dashboard temperature in °C.
  double? get temperature => toDoubleOrNull(info['dt']);

  /// Extra filesystem usage percentages by name.
  Map<String, double> get extraFs {
    final efs = asMap(info['efs']);
    return efs.map((k, v) => MapEntry(k, toDouble(v)));
  }

  /// Custom root disk name.
  String? get rootDiskName => info['rdn'] as String?;

  /// systemd services [total, failed].
  List<int> get services {
    final sv = info['sv'];
    if (sv is List && sv.length >= 2) return [toInt(sv[0]), toInt(sv[1])];
    return const [];
  }

  /// Battery [percent, state].
  (int, BatteryState)? get battery {
    final bat = info['bat'];
    if (bat is List && bat.length >= 2) {
      final state = toInt(bat[1]);
      return (
        toInt(bat[0]),
        state >= 0 && state < BatteryState.values.length
            ? BatteryState.values[state]
            : BatteryState.unknown,
      );
    }
    return null;
  }

  /// Pending package updates [total, security?].
  List<int> get pendingUpdates {
    final pu = info['pu'];
    if (pu is List && pu.isNotEmpty) return pu.map(toInt).toList();
    return const [];
  }

  /// Connected Wi-Fi interfaces: iface -> (ssid, rssi dBm).
  Map<String, (String?, double?)> get wifi {
    final wf = asMap(info['wf']);
    return wf.map((k, v) {
      final m = asMap(v);
      return MapEntry(k, (m['s'] as String?, toDoubleOrNull(m['r'])));
    });
  }

  /// Connection type: 1 SSH, 2 WebSocket.
  int get connectionType => toInt(info['ct']);

  bool get journalAvailable => info['jl'] == true;
}

/// Static system information (`system_details` collection, agent >= 0.15).
class SystemDetails {
  final String hostname;
  final String kernel;
  final String cpu;
  final String osName;
  final String arch;
  final SystemOs os;
  final int cores;
  final int threads;
  final double memory; // bytes
  final bool podman;

  SystemDetails({
    required this.hostname,
    required this.kernel,
    required this.cpu,
    required this.osName,
    required this.arch,
    required this.os,
    required this.cores,
    required this.threads,
    required this.memory,
    required this.podman,
  });

  factory SystemDetails.fromRecord(RecordModel r) => SystemDetails(
    hostname: r.getStringValue('hostname'),
    kernel: r.getStringValue('kernel'),
    cpu: r.getStringValue('cpu'),
    osName: r.getStringValue('os_name'),
    arch: r.getStringValue('arch'),
    os: systemOsFromValue(toInt(r.data['os'])),
    cores: toInt(r.data['cores']),
    threads: toInt(r.data['threads']),
    memory: toDouble(r.data['memory']),
    podman: r.data['podman'] == true,
  );

  /// Builds details from the legacy `info` keys of old agents.
  factory SystemDetails.fromLegacyInfo(System s) => SystemDetails(
    hostname: s.hostname ?? '',
    kernel: s.kernel ?? '',
    cpu: s.cpuModel ?? '',
    osName: '',
    arch: '',
    os: s.os,
    cores: s.cores,
    threads: s.threads,
    memory: 0,
    podman: s.info['p'] == true,
  );
}
