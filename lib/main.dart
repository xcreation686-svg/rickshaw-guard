// RickshawGuard - a small utility to help e-rickshaw owners secure THEIR OWN
// Bluetooth BMS: restore power if someone cuts it, watch for tampering, and
// (on BMS models that support it) set a password.
//
// Target BMS in this scaffold: JBD / Xiaoxiang (BLE service 0xFF00).
// The protocol layer is pluggable so other BMS (JK-BMS, Daly...) can be added.
//
// IMPORTANT SAFETY / ETHICS:
//   * You connect to and control your OWN rickshaw (you pick your device and
//     can "remember" it). This is device security, exactly like the stock app.
//   * If you set a password, WRITE IT DOWN. If you forget it you can lock
//     yourself out of your own BMS.
//
// Requires (pubspec.yaml):
//   flutter_blue_plus: ^1.32.0
//   permission_handler: ^11.3.0
//   shared_preferences: ^2.2.0

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const RickshawGuardApp());

class RickshawGuardApp extends StatelessWidget {
  const RickshawGuardApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RickshawGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF00695C),
        brightness: Brightness.light,
      ),
      home: const ScanScreen(),
    );
  }
}

/* ----------------------------------------------------------------------------
 * PROTOCOL LAYER
 * Abstract so each BMS family has its own implementation. Only JBD/Xiaoxiang
 * is fully implemented here.
 * ------------------------------------------------------------------------- */

class BmsStatus {
  final double? voltage; // pack volts
  final double? current; // amps (negative = discharge on many packs)
  final int? soc; // %
  final bool? chargeFet; // true = ON
  final bool? dischargeFet; // true = ON  <-- the one attackers turn OFF
  const BmsStatus(
      {this.voltage, this.current, this.soc, this.chargeFet, this.dischargeFet});
}

abstract class BmsProtocol {
  String get serviceHint; // substring of the BLE service UUID
  String get notifyHint; // characteristic that sends data back
  String get writeHint; // characteristic we write commands to

  /// Whether this BMS family exposes a settable connection password.
  bool get supportsPassword;

  List<int> cmdReadStatus();
  List<int> cmdPowerOn(); // turn charge + discharge FET back ON

  /// Only meaningful when supportsPassword == true. Returns the bytes to write.
  /// Left unimplemented on families where we haven't verified the exact frame,
  /// so we never send guessed bytes to real hardware.
  List<int> cmdSetPassword(String password) =>
      throw UnimplementedError('Password change not verified for this BMS.');

  /// Parse a fully reassembled frame into a status object (or null if not a
  /// status frame).
  BmsStatus? parseStatus(List<int> frame);

  /// Reassemble streamed BLE chunks into complete frames.
  List<List<int>> feed(List<int> chunk);
}

/// JBD / Xiaoxiang / Overkill-Solar style BMS.
/// Frames: 0xDD ... 0x77. Checksum = 0x10000 - sum(payload), big-endian.
class JbdProtocol extends BmsProtocol {
  final List<int> _buf = [];

  @override
  String get serviceHint => 'ff00';
  @override
  String get notifyHint => 'ff01';
  @override
  String get writeHint => 'ff02';

  // JBD base firmware typically has NO Bluetooth password. So we don't pretend.
  @override
  bool get supportsPassword => false;

  List<int> _checksum(List<int> payload) {
    int sum = payload.fold(0, (a, b) => a + b);
    int chk = (0x10000 - sum) & 0xFFFF;
    return [(chk >> 8) & 0xFF, chk & 0xFF];
  }

  List<int> _read(int reg) {
    final payload = [reg, 0x00];
    return [0xDD, 0xA5, ...payload, ..._checksum(payload), 0x77];
  }

  List<int> _write(int reg, List<int> data) {
    final payload = [reg, data.length, ...data];
    return [0xDD, 0x5A, ...payload, ..._checksum(payload), 0x77];
  }

  @override
  List<int> cmdReadStatus() => _read(0x03); // basic info

  @override
  List<int> cmdPowerOn() => _write(0xE1, [0x00, 0x00]); // both FETs ON

  @override
  List<List<int>> feed(List<int> chunk) {
    _buf.addAll(chunk);
    final frames = <List<int>>[];
    while (true) {
      final start = _buf.indexOf(0xDD);
      if (start < 0) {
        _buf.clear();
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      final end = _buf.indexOf(0x77, 1);
      if (end < 0) break; // wait for more bytes
      frames.add(_buf.sublist(0, end + 1));
      _buf.removeRange(0, end + 1);
    }
    return frames;
  }

  @override
  BmsStatus? parseStatus(List<int> f) {
    // Basic-info reply looks like: DD 03 <len> <payload...> <chk> <chk> 77
    if (f.length < 6 || f[1] != 0x03) return null;
    final len = f[2];
    final p = f.sublist(3, 3 + len);
    if (p.length < 23) return null;

    int u16(int i) => (p[i] << 8) | p[i + 1];
    int s16(int i) {
      final v = u16(i);
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    final voltage = u16(0) / 100.0; // 10 mV units
    final current = s16(2) / 100.0; // 10 mA units
    final soc = p[19];
    final fet = p[20];
    return BmsStatus(
      voltage: voltage,
      current: current,
      soc: soc,
      chargeFet: (fet & 0x01) != 0,
      dischargeFet: (fet & 0x02) != 0,
    );
  }
}

/* ----------------------------------------------------------------------------
 * SCAN SCREEN
 * ------------------------------------------------------------------------- */

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final List<ScanResult> _results = [];
  StreamSubscription? _sub;
  bool _scanning = false;
  String? _rememberedId;

  @override
  void initState() {
    super.initState();
    _loadRemembered();
  }

  Future<void> _loadRemembered() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _rememberedId = prefs.getString('my_rickshaw_id'));
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // required for scanning on older Android
    ].request();
  }

  Future<void> _startScan() async {
    await _requestPermissions();
    setState(() {
      _results.clear();
      _scanning = true;
    });
    _sub?.cancel();
    _sub = FlutterBluePlus.scanResults.listen((list) {
      setState(() {
        _results
          ..clear()
          ..addAll(list.where((r) => r.device.platformName.isNotEmpty));
      });
    });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    setState(() => _scanning = false);
  }

  @override
  void dispose() {
    _sub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RickshawGuard'),
        actions: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Select your rickshaw\u2019s BMS from the list. '
              'Tip: check the Bluetooth name on your BMS sticker so you connect '
              'to the right one.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(_scanning ? 'Scanning\u2026' : 'No devices yet'))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final id = r.device.remoteId.str;
                      final isMine = id == _rememberedId;
                      return ListTile(
                        leading: Icon(isMine
                            ? Icons.electric_rickshaw
                            : Icons.bluetooth),
                        title: Text(r.device.platformName),
                        subtitle: Text('$id   ${r.rssi} dBm'),
                        trailing:
                            isMine ? const Chip(label: Text('My rickshaw')) : null,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DeviceScreen(device: r.device),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _startScan,
        icon: const Icon(Icons.search),
        label: const Text('Scan'),
      ),
    );
  }
}

/* ----------------------------------------------------------------------------
 * DEVICE SCREEN - connect, restore power, monitor, (set password)
 * ------------------------------------------------------------------------- */

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;
  const DeviceScreen({super.key, required this.device});
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  final BmsProtocol _proto = JbdProtocol();
  BluetoothCharacteristic? _write;
  BluetoothCharacteristic? _notify;
  StreamSubscription? _valueSub;
  StreamSubscription? _connSub;
  Timer? _poll;

  BmsStatus _status = const BmsStatus();
  bool _connected = false;
  bool _monitor = false;
  String _log = '';

  void _addLog(String s) => setState(() => _log = '$s\n$_log');

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    _connSub = widget.device.connectionState.listen((s) {
      setState(() => _connected = s == BluetoothConnectionState.connected);
    });
    try {
      await widget.device.connect(timeout: const Duration(seconds: 12));
      final services = await widget.device.discoverServices();
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains(_proto.serviceHint)) continue;
        for (final c in svc.characteristics) {
          final u = c.uuid.str.toLowerCase();
          if (u.contains(_proto.notifyHint)) _notify = c;
          if (u.contains(_proto.writeHint)) _write = c;
        }
      }
      if (_notify != null) {
        await _notify!.setNotifyValue(true);
        _valueSub = _notify!.onValueReceived.listen(_onData);
      }
      _addLog('Connected. Reading status\u2026');
      _startPolling();
    } catch (e) {
      _addLog('Connect failed: $e');
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _readStatus());
    _readStatus();
  }

  void _onData(List<int> chunk) {
    for (final frame in _proto.feed(chunk)) {
      final st = _proto.parseStatus(frame);
      if (st != null) {
        setState(() => _status = st);
        // Anti-tamper core: if monitoring and discharge got switched OFF while
        // the pack is otherwise fine, put it back ON.
        if (_monitor && st.dischargeFet == false) {
          _addLog('Discharge OFF detected \u2014 restoring power.');
          _powerOn();
        }
      }
    }
  }

  Future<void> _send(List<int> cmd) async {
    if (_write == null) {
      _addLog('No writable characteristic.');
      return;
    }
    // withoutResponse is typical for these BMS write characteristics.
    await _write!.write(cmd, withoutResponse: true);
  }

  Future<void> _readStatus() => _send(_proto.cmdReadStatus());

  Future<void> _powerOn() async {
    await _send(_proto.cmdPowerOn());
    _addLog('Sent: turn power ON');
  }

  String _randomPassword([int len = 8]) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> _rememberThis() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('my_rickshaw_id', widget.device.remoteId.str);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved as your rickshaw')),
      );
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _valueSub?.cancel();
    _connSub?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _status.dischargeFet;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName.isEmpty
            ? 'BMS'
            : widget.device.platformName),
        actions: [
          IconButton(
              onPressed: _rememberThis,
              icon: const Icon(Icons.push_pin_outlined),
              tooltip: 'Remember as my rickshaw'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(connected: _connected, status: _status),
          const SizedBox(height: 16),

          // Restore power
          FilledButton.icon(
            onPressed: _connected ? _powerOn : null,
            icon: const Icon(Icons.power_settings_new),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56)),
            label: Text(d == false ? 'Restore power NOW' : 'Force power ON'),
          ),
          const SizedBox(height: 8),

          // Monitor / auto-restore
          SwitchListTile(
            value: _monitor,
            onChanged: _connected ? (v) => setState(() => _monitor = v) : null,
            title: const Text('Watch & auto-restore'),
            subtitle: const Text(
                'If someone switches your power off, turn it back on automatically. '
                'Keep this screen open while riding.'),
          ),
          const SizedBox(height: 8),

          // Password section
          _PasswordSection(
            supported: _proto.supportsPassword,
            onGenerate: _randomPassword,
            onSet: (pw) async {
              try {
                await _send(_proto.cmdSetPassword(pw));
                _addLog('Password command sent. SAVE this password: $pw');
              } catch (e) {
                _addLog('$e');
              }
            },
          ),

          const SizedBox(height: 16),
          Text('Activity', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_log.isEmpty ? '\u2014' : _log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool connected;
  final BmsStatus status;
  const _StatusCard({required this.connected, required this.status});

  @override
  Widget build(BuildContext context) {
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(k), Text(v, style: const TextStyle(fontWeight: FontWeight.w600))],
          ),
        );
    String b(bool? x) => x == null ? '\u2014' : (x ? 'ON' : 'OFF');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(children: [
              Icon(connected ? Icons.link : Icons.link_off,
                  color: connected ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Text(connected ? 'Connected' : 'Not connected'),
            ]),
            const Divider(),
            row('Pack voltage',
                status.voltage == null ? '\u2014' : '${status.voltage!.toStringAsFixed(2)} V'),
            row('Current',
                status.current == null ? '\u2014' : '${status.current!.toStringAsFixed(2)} A'),
            row('Charge', status.soc == null ? '\u2014' : '${status.soc}%'),
            row('Discharge output', b(status.dischargeFet)),
            row('Charge input', b(status.chargeFet)),
          ],
        ),
      ),
    );
  }
}

class _PasswordSection extends StatefulWidget {
  final bool supported;
  final String Function() onGenerate;
  final Future<void> Function(String) onSet;
  const _PasswordSection(
      {required this.supported, required this.onGenerate, required this.onSet});
  @override
  State<_PasswordSection> createState() => _PasswordSectionState();
}

class _PasswordSectionState extends State<_PasswordSection> {
  final _ctrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    if (!widget.supported) {
      return Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'This BMS type has no connection password to change. '
            'Use "Watch & auto-restore" above, and consider physically '
            'shielding/replacing the Bluetooth module to block strangers.',
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Set a password (locks out strangers)',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'New password',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.casino),
                  tooltip: 'Generate strong password',
                  onPressed: () => _ctrl.text = widget.onGenerate(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                if (_ctrl.text.isEmpty) return;
                await widget.onSet(_ctrl.text);
              },
              child: const Text('Set password'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Write it down \u2014 if you forget it you can lock '
                  'yourself out of your own BMS.',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
