import 'package:pocketbase/pocketbase.dart';
import 'package:beszel_pro/utils/format.dart';

/// Current container state (`containers` collection, agent >= 0.14).
class ContainerInfo {
  final String id;
  final String name;
  final String image;
  final String ports;
  final String status;

  /// 0 none, 1 starting, 2 healthy, 3 unhealthy
  final int health;
  final double cpu; // %
  final double memory; // MB
  final double net; // bytes/s
  final bool updatable;
  final int updated; // unix ms

  ContainerInfo({
    required this.id,
    required this.name,
    required this.image,
    required this.ports,
    required this.status,
    required this.health,
    required this.cpu,
    required this.memory,
    required this.net,
    required this.updatable,
    required this.updated,
  });

  factory ContainerInfo.fromRecord(RecordModel r) => ContainerInfo(
    id: r.id,
    name: r.getStringValue('name'),
    image: r.getStringValue('image'),
    ports: r.getStringValue('ports'),
    status: r.getStringValue('status'),
    health: toInt(r.data['health']),
    cpu: toDouble(r.data['cpu']),
    memory: toDouble(r.data['memory']),
    net: toDouble(r.data['net']),
    updatable: r.data['updatable'] == true,
    updated: toInt(r.data['updated']),
  );

  bool get isRunning => status.toLowerCase().startsWith('up');
}

/// systemd service (`systemd_services` collection).
class SystemdService {
  final String id;
  final String name;

  /// 0 active, 1 inactive, 2 failed, 3 activating, 4 deactivating, 5 reloading
  final int state;

  /// 0 dead, 1 running, 2 exited, 3 failed, 4 unknown
  final int sub;
  final double cpu;
  final double cpuPeak;
  final double memory; // bytes
  final double memPeak; // bytes
  final int updated; // unix ms

  SystemdService({
    required this.id,
    required this.name,
    required this.state,
    required this.sub,
    required this.cpu,
    required this.cpuPeak,
    required this.memory,
    required this.memPeak,
    required this.updated,
  });

  factory SystemdService.fromRecord(RecordModel r) => SystemdService(
    id: r.id,
    name: r.getStringValue('name'),
    state: toInt(r.data['state']),
    sub: toInt(r.data['sub']),
    cpu: toDouble(r.data['cpu']),
    cpuPeak: toDouble(r.data['cpuPeak']),
    memory: toDouble(r.data['memory']),
    memPeak: toDouble(r.data['memPeak']),
    updated: toInt(r.data['updated']),
  );

  static const stateNames = [
    'active',
    'inactive',
    'failed',
    'activating',
    'deactivating',
    'reloading',
  ];
  static const subNames = ['dead', 'running', 'exited', 'failed', 'unknown'];

  String get stateName =>
      state >= 0 && state < stateNames.length ? stateNames[state] : '?';
  String get subName =>
      sub >= 0 && sub < subNames.length ? subNames[sub] : '?';
  bool get isFailed => state == 2 || sub == 3;
}

/// S.M.A.R.T. disk (`smart_devices` collection, agent >= 0.15).
class SmartDevice {
  final String id;
  final String name;
  final String model;
  final String serial;
  final String firmware;
  final String state;
  final String type;
  final double capacity; // bytes
  final double? temp;
  final int hours;
  final int cycles;
  final List<SmartAttribute> attributes;
  final String updated;

  SmartDevice({
    required this.id,
    required this.name,
    required this.model,
    required this.serial,
    required this.firmware,
    required this.state,
    required this.type,
    required this.capacity,
    required this.temp,
    required this.hours,
    required this.cycles,
    required this.attributes,
    required this.updated,
  });

  factory SmartDevice.fromRecord(RecordModel r) => SmartDevice(
    id: r.id,
    name: r.getStringValue('name'),
    model: r.getStringValue('model'),
    serial: r.getStringValue('serial'),
    firmware: r.getStringValue('firmware'),
    state: r.getStringValue('state'),
    type: r.getStringValue('type'),
    capacity: toDouble(r.data['capacity']),
    temp: toDoubleOrNull(r.data['temp']),
    hours: toInt(r.data['hours']),
    cycles: toInt(r.data['cycles']),
    attributes: (r.data['attributes'] is List)
        ? (r.data['attributes'] as List)
              .map((a) => SmartAttribute(asMap(a)))
              .toList()
        : const [],
    updated: r.getStringValue('updated'),
  );

  bool get passed => state.toUpperCase() == 'PASSED';
  bool get failed => state.toUpperCase() == 'FAILED';
}

class SmartAttribute {
  final Map<String, dynamic> raw;
  SmartAttribute(this.raw);

  int? get id => raw['id'] is num ? toInt(raw['id']) : null;
  String get name => raw['n']?.toString() ?? '';
  num? get value => raw['v'] as num?;
  num? get worst => raw['w'] as num?;
  num? get threshold => raw['t'] as num?;
  String get rawValue =>
      raw['rs']?.toString() ?? raw['rv']?.toString() ?? '';
  String? get whenFailed {
    final wf = raw['wf']?.toString();
    return (wf == null || wf.isEmpty || wf == '-') ? null : wf;
  }
}

/// Server side alert event (`alerts_history`).
class HubAlertEvent {
  final String id;
  final String name;
  final String systemId;
  final String systemName;
  final String monitorName;
  final double value;
  final DateTime? created;
  final DateTime? resolved;

  HubAlertEvent({
    required this.id,
    required this.name,
    required this.systemId,
    required this.systemName,
    required this.monitorName,
    required this.value,
    required this.created,
    required this.resolved,
  });

  factory HubAlertEvent.fromRecord(RecordModel r) {
    return HubAlertEvent(
      id: r.id,
      name: r.getStringValue('name'),
      systemId: r.getStringValue('system'),
      systemName: r.getStringValue('expand.system.name'),
      monitorName: r.getStringValue('monitor_name'),
      value: toDouble(r.data['value']),
      created: parsePbDate(r.data['created']),
      resolved: parsePbDate(r.data['resolved']),
    );
  }

  bool get isActive => resolved == null;
}

/// Alert rule configured on the hub (`alerts`).
class HubAlertRule {
  final String id;
  final String name;
  final String systemId;
  final double value;
  final int min;
  final bool triggered;

  HubAlertRule({
    required this.id,
    required this.name,
    required this.systemId,
    required this.value,
    required this.min,
    required this.triggered,
  });

  factory HubAlertRule.fromRecord(RecordModel r) => HubAlertRule(
    id: r.id,
    name: r.getStringValue('name'),
    systemId: r.getStringValue('system'),
    value: toDouble(r.data['value']),
    min: toInt(r.data['min']),
    triggered: r.data['triggered'] == true,
  );
}
