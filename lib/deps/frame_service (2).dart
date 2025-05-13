import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_sdk/camera.dart';
import 'package:frame_sdk/frame_sdk.dart' as frame_sdk;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ar_project/services/storage_service.dart';
import '../models/LogEntry.dart';

class FrameService {
  final Logger _log = Logger('FrameService');
  final StorageService? storageService;

  frame_sdk.Frame? _frame;
  bool _isConnected = false;
  bool _mtuSet = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 5;
  static const Duration _scanTimeout = Duration(seconds: 15);

  List<ScanResult> _discoveredDevices = [];

  FrameService({this.storageService}) {
    _log.info('FrameService initialized');
    debugPrint('[FrameService] FrameService initialized');
  }

  Future<bool> initialize() async {
    debugPrint('[FrameService] Initializing Bluetooth...');

    if (!await Geolocator.isLocationServiceEnabled()) {
      _log.warning('Location services are disabled');
      addLogMessage('Please enable location services to connect to Frame glasses');
      await Geolocator.openLocationSettings();
      if (!await Geolocator.isLocationServiceEnabled()) {
        _log.severe('Location services not enabled');
        addLogMessage('Location services required for Bluetooth scanning');
        return false;
      }
    }

    int attempts = 0;
    while (attempts < 2) {
      attempts++;
      var statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      if (statuses.values.every((s) => s.isGranted)) return true;
      addLogMessage('Please grant all permissions to connect to Frame glasses');
      await Future.delayed(const Duration(seconds: 2));
    }

    _log.severe('Failed to get required permissions');
    addLogMessage('Failed to get required permissions');
    return false;
  }

  Future<void> connectToGlasses() async {
    if (_isConnected) {
      addLogMessage('Already connected, skipping connection attempt');
      return;
    }
    if (!await initialize()) throw Exception('Bluetooth initialization failed');

    for (int scanAttempt = 1; scanAttempt <= 2 && !_isConnected; scanAttempt++) {
      addLogMessage('Scanning for Frame devices (attempt $scanAttempt/2)');
      _discoveredDevices.clear();
      await _scanDevices();

      if (_discoveredDevices.isEmpty) {
        addLogMessage('No Frame devices found');
        if (scanAttempt < 2) await Future.delayed(Duration(seconds: _retryDelaySeconds));
        continue;
      }

      final target = _discoveredDevices.firstWhere(
        (d) => d.rssi >= -80,
        orElse: () => throw Exception('No Frame device with sufficient signal strength'),
      );
      addLogMessage('Selected device: ${target.device.remoteId}');

      for (int attempt = 1; attempt <= _maxRetries && !_isConnected; attempt++) {
        try {
          await target.device.connect(autoConnect: false, timeout: Duration(seconds: 10));
          bool bonded = await _ensureBonding(target.device);
          if (!bonded) addLogMessage('Proceeding without bonding');

          // Give Android a moment
          await Future.delayed(Duration(milliseconds: 500));

          // Discover services then MTU
          await target.device.discoverServices();
          addLogMessage('Services discovered');

          if (!_mtuSet) {
            int mtu = await target.device.requestMtu(247);
            addLogMessage('MTU set to $mtu');
            _mtuSet = true;
          }

          _stateSub = target.device.state.listen((s) {
            if (s == BluetoothConnectionState.disconnected) {
              addLogMessage('Device disconnected');
            }
          });

          _isConnected = true;
          _frame = frame_sdk.Frame();
          await _frame!.connect();
          break;
        } catch (e) {
          addLogMessage('Connect attempt $attempt failed: $e');
          if (attempt < _maxRetries) await Future.delayed(Duration(seconds: _retryDelaySeconds));
          else rethrow;
        }
      }
    }
  }

  Future<void> _scanDevices() async {
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (var r in results) {
        if (r.advertisementData.serviceUuids.contains(Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')) ||
            r.advertisementData.serviceUuids.contains(Guid('fe59'))) {
          if (!_discoveredDevices.any((d) => d.device.remoteId == r.device.remoteId)) {
            _discoveredDevices.add(r);
          }
        }
      }
    });
    await FlutterBluePlus.startScan(
      withServices: [
        Guid('7a230001-5475-a6a4-654c-8431f6ad49c4'),
        Guid('fe59'),
      ],
      timeout: _scanTimeout,
    );
    await Future.delayed(_scanTimeout);
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
  }

  Future<bool> _ensureBonding(BluetoothDevice device) async {
    var completer = Completer<bool>();
    var sub = device.bondState.listen((state) {
      if (state == BluetoothBondState.bonded) completer.complete(true);
      else if (state == BluetoothBondState.none) completer.complete(false);
    });
    await device.createBond();
    bool result = await completer.future.timeout(Duration(seconds: 20), onTimeout: () => false);
    await sub.cancel();
    return result;
  }

  Future<List<int>> capturePhoto() async {
    if (!_isConnected || _frame == null) throw Exception('Not connected');
    addLogMessage('Capturing photo');
    final photo = await _frame!.camera.takePhoto(
      autofocusSeconds: 1,
      quality: PhotoQuality.full,
      autofocusType: AutoFocusType.average,
    );
    return photo;
  }

  Future<void> disconnect() async {
    if (!_isConnected) return;
    await _frame?.disconnect();
    if (_discoveredDevices.isNotEmpty) {
      await _discoveredDevices.first.device.disconnect();
    }
    await _stateSub?.cancel();
    _isConnected = false;
    _mtuSet = false;
    _frame = null;
    addLogMessage('Disconnected from Frame glasses');
  }

  bool get isConnected => _isConnected;
  frame_sdk.Frame? get frame => _frame;

  void addLogMessage(String message) {
    storageService?.saveLog(LogEntry(DateTime.now(), message));
    debugPrint('[FrameService] $message');
  }
}