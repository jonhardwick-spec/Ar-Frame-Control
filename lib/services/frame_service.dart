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
import '../models/log_entry.dart';

class FrameService {
  final Logger _log = Logger('FrameService');
  frame_sdk.Frame? _frame;
  bool _isConnected = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  final StorageService storageService;
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 5;
  static const Duration _scanTimeout = Duration(seconds: 15);
  bool _mtuSet = false;
  List<ScanResult> _discoveredDevices = [];
  BluetoothDevice? _lastConnectedDevice;
  bool _isOperationRunning = false; // Semaphore to prevent concurrent operations

  final connectionState = ValueNotifier<bool>(false);

  FrameService({required this.storageService}) {
    _log.info('FrameService initialized');
    debugPrint('[FrameService] FrameService initialized');
    _updateConnectionState(false);
  }

  void _updateConnectionState(bool state) {
    _isConnected = state;
    connectionState.value = state;
    _log.info('Connection state updated to: $state');
    storageService.saveLog(LogEntry(DateTime.now(), 'Connection state updated to: $state'));
  }

  Future<bool> initialize() async {
    debugPrint('[FrameService] Initializing Bluetooth...');

    if (!await Geolocator.isLocationServiceEnabled()) {
      _log.warning('Location services are disabled');
      debugPrint('[FrameService] Location services are disabled');
      addLogMessage('Please enable location services to connect to Frame glasses');
      await Geolocator.openLocationSettings();
      if (!await Geolocator.isLocationServiceEnabled()) {
        _log.severe('Location services not enabled');
        debugPrint('[FrameService] Location services not enabled');
        addLogMessage('Location services required for Bluetooth scanning');
        return false;
      }
    }

    int attempts = 0;
    const maxAttempts = 2;
    while (attempts < maxAttempts) {
      var statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      if (statuses.values.every((s) => s.isGranted)) {
        debugPrint('[FrameService] All permissions granted');
        return true;
      }
      attempts++;
      _log.warning('Permissions not granted: $statuses');
      debugPrint('[FrameService] Permissions not granted: $statuses');
      addLogMessage('Please grant all permissions to connect to Frame glasses');
      if (attempts < maxAttempts) {
        _log.info('Retrying permission request in 2 seconds...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    _log.severe('Failed to get required permissions');
    debugPrint('[FrameService] Failed to get required permissions');
    addLogMessage('Failed to get required permissions');
    return false;
  }

  Future<void> connectToGlasses() async {
    if (_isConnected && await verifyConnection()) {
      _log.info('Already connected, skipping connection attempt');
      addLogMessage('Already connected, skipping connection attempt');
      debugPrint('[FrameService] Already connected, skipping connection attempt');
      return;
    }

    if (!await initialize()) {
      throw Exception('Bluetooth initialization failed');
    }

    for (int scanAttempt = 1; scanAttempt <= 2 && !_isConnected; scanAttempt++) {
      _log.info('Scanning for Frame devices (attempt $scanAttempt/2)');
      addLogMessage('Scanning for Frame devices (attempt $scanAttempt/2)');
      debugPrint('[FrameService] Scanning for Frame devices (attempt $scanAttempt/2)');

      try {
        _discoveredDevices.clear();
        await _scanDevices();

        if (_discoveredDevices.isEmpty) {
          _log.warning('No Frame devices found in scan attempt $scanAttempt');
          addLogMessage('No Frame devices found in scan attempt $scanAttempt');
          debugPrint('[FrameService] No Frame devices found in scan attempt $scanAttempt');
          if (scanAttempt < 2) {
            _log.info('Retrying scan in $_retryDelaySeconds seconds...');
            await Future.delayed(const Duration(seconds: _retryDelaySeconds));
          }
          continue;
        }

        _log.info('Found ${_discoveredDevices.length} Frame devices: ${_discoveredDevices.map((d) => "${d.device.platformName} (${d.device.remoteId})").join(", ")}');
        addLogMessage('Found ${_discoveredDevices.length} Frame devices');
        debugPrint('[FrameService] Found ${_discoveredDevices.length} Frame devices');

        final target = _discoveredDevices.firstWhere(
              (d) => d.rssi >= -80,
          orElse: () => throw Exception('No Frame device with sufficient signal strength (min RSSI: -80)'),
        );
        _log.info('Selected device: ${target.device.platformName} (${target.device.remoteId}), RSSI: ${target.rssi}');
        addLogMessage('Selected device: ${target.device.platformName} (${target.device.remoteId})');
        debugPrint('[FrameService] Selected device: ${target.device.platformName} (${target.device.remoteId}), RSSI: ${target.rssi}');

        for (int attempt = 1; attempt <= _maxRetries && !_isConnected; attempt++) {
          try {
            _log.info('Attempting to connect to device ${target.device.remoteId} (retry $attempt/$_maxRetries)');
            addLogMessage('Attempting to connect to device ${target.device.remoteId} (retry $attempt/$_maxRetries)');
            debugPrint('[FrameService] Attempting to connect to device ${target.device.remoteId} (retry $attempt/$_maxRetries)');

            if (await target.device.connectionState.first == BluetoothConnectionState.connected) {
              _log.info('Device already connected, proceeding with setup');
              debugPrint('[FrameService] Device already connected, proceeding with setup');
            } else {
              await target.device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
            }

            bool bonded = await _ensureBonding(target.device);
            if (!bonded) {
              _log.warning('Bonding failed, proceeding without bonding');
              addLogMessage('Bonding failed, proceeding without bonding');
              debugPrint('[FrameService] Bonding failed, proceeding without bonding');
            }

            await Future.delayed(const Duration(seconds: 1));
            if (await target.device.connectionState.first != BluetoothConnectionState.connected) {
              throw Exception('Device disconnected during setup');
            }

            if (!_mtuSet) {
              for (int mtuAttempt = 1; mtuAttempt <= 2; mtuAttempt++) {
                try {
                  _log.info('Configuring MTU to 247 (attempt $mtuAttempt/2)...');
                  addLogMessage('Configuring MTU to 247 (attempt $mtuAttempt/2)...');
                  debugPrint('[FrameService] Configuring MTU to 247 (attempt $mtuAttempt/2)...');
                  int mtu = await target.device.requestMtu(247);
                  _log.info('MTU set to $mtu');
                  addLogMessage('MTU set to $mtu');
                  debugPrint('[FrameService] MTU set to $mtu');
                  _mtuSet = true;
                  break;
                } catch (e) {
                  _log.warning('MTU configuration failed: $e');
                  debugPrint('[FrameService] MTU configuration failed: $e');
                  if (mtuAttempt == 2) {
                    _log.warning('Proceeding without MTU configuration');
                    addLogMessage('Proceeding without MTU configuration');
                    debugPrint('[FrameService] Proceeding without MTU configuration');
                  } else {
                    await Future.delayed(const Duration(milliseconds: 500));
                  }
                }
              }
            }

            if (await target.device.connectionState.first != BluetoothConnectionState.connected) {
              throw Exception('Device disconnected before service discovery');
            }

            _log.info('Discovering services...');
            debugPrint('[FrameService] Discovering services...');
            await target.device.discoverServices();
            _log.info('Services discovered');
            addLogMessage('Services discovered');
            debugPrint('[FrameService] Services discovered');

            _stateSub?.cancel();
            _stateSub = target.device.connectionState.listen((state) {
              _log.info('Connection state changed: $state');
              debugPrint('[FrameService] Connection state changed: $state');
              addLogMessage('Connection state changed: $state');
              if (state == BluetoothConnectionState.disconnected) {
                _updateConnectionState(false);
                _frame = null;
                _mtuSet = false;
                _lastConnectedDevice = null;
                _log.severe('Device disconnected unexpectedly');
                addLogMessage('Device disconnected unexpectedly');
                debugPrint('[FrameService] Device disconnected unexpectedly');
                _stopScan();
              }
            });

            _frame = frame_sdk.Frame();
            await _frame!.connect();
            _updateConnectionState(true);
            _lastConnectedDevice = target.device;
            _log.info('Successfully connected to Frame glasses');
            addLogMessage('Successfully connected to Frame glasses');
            debugPrint('[FrameService] Successfully connected to Frame glasses');
            await _stopScan();
            await _sendConnectedIndicator();
            break;
          } catch (e) {
            _log.severe('Error connecting to device ${target.device.remoteId}: $e');
            addLogMessage('Error connecting to device ${target.device.remoteId}: $e');
            debugPrint('[FrameService] Error connecting to device ${target.device.remoteId}: $e');
            if (attempt < _maxRetries) {
              _log.info('Retrying in $_retryDelaySeconds seconds...');
              await Future.delayed(const Duration(seconds: _retryDelaySeconds));
            } else {
              _updateConnectionState(false);
              throw Exception('Connection failed after maximum retries');
            }
          }
        }
      } catch (e) {
        _log.severe('Error during scan and connect: $e');
        addLogMessage('Error during scan and connect: $e');
        debugPrint('[FrameService] Error during scan and connect: $e');
        if (scanAttempt >= 2) {
          _updateConnectionState(false);
          throw Exception('Failed to connect: $e');
        }
      }
    }
  }

  Future<void> _sendConnectedIndicator() async {
    try {
      await _frame!.runLua('frame.display.text("Connected to AR Control", 0, 0)');
      _log.info('Sent connected indicator to glasses');
      addLogMessage('Sent connected indicator to glasses');
    } catch (e) {
      _log.severe('Failed to send connected indicator: $e');
      addLogMessage('Failed to send connected indicator: $e');
    }
  }

  Future<void> _scanDevices() async {
    if (_isConnected) {
      _log.info('Skipping scan: Already connected');
      debugPrint('[FrameService] Skipping scan: Already connected');
      addLogMessage('Skipping scan: Already connected');
      return;
    }

    await _stopScan();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (var r in results) {
        if (r.advertisementData.serviceUuids.contains(Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')) ||
            r.advertisementData.serviceUuids.contains(Guid('fe59'))) {
          if (!_discoveredDevices.any((d) => d.device.remoteId == r.device.remoteId)) {
            _discoveredDevices.add(r);
            _log.fine('Found Frame device: ${r.device.platformName} (${r.device.remoteId}), RSSI: ${r.rssi}');
            debugPrint('[FrameService] Found Frame device: ${r.device.platformName} (${r.device.remoteId}), RSSI: ${r.rssi}');
          }
        }
      }
    }, onError: (e) {
      _log.severe('Scan error: $e');
      addLogMessage('Scan error: $e');
      debugPrint('[FrameService] Scan error: $e');
    });

    await FlutterBluePlus.startScan(
      withServices: [
        Guid('7a230001-5475-a6a4-654c-8431f6ad49c4'),
        Guid('fe59'),
      ],
      timeout: _scanTimeout,
    );
    await Future.delayed(_scanTimeout);
    await _stopScan();
  }

  Future<void> _stopScan() async {
    if (_scanSubscription != null) {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _log.info('Scan stopped');
      debugPrint('[FrameService] Scan stopped');
      addLogMessage('Scan stopped');
    }
  }

  Future<bool> _ensureBonding(BluetoothDevice device) async {
    try {
      var completer = Completer<bool>();
      StreamSubscription<BluetoothBondState>? bondSubscription;

      bondSubscription = device.bondState.listen((state) {
        _log.info('Bond state changed: $state');
        addLogMessage('Bond state changed: $state');
        debugPrint('[FrameService] Bond state changed: $state');
        if (state == BluetoothBondState.bonded) {
          _log.info('Bonding complete');
          addLogMessage('Bonding complete');
          debugPrint('[FrameService] Bonding complete');
          completer.complete(true);
        } else if (state == BluetoothBondState.none) {
          _log.warning('Bonding failed or not bonded');
          addLogMessage('Bonding failed or not bonded');
          debugPrint('[FrameService] Bonding failed or not bonded');
          completer.complete(false);
        }
      });

      await device.createBond();
      bool bonded = await completer.future.timeout(const Duration(seconds: 20), onTimeout: () {
        _log.warning('Bonding timed out');
        addLogMessage('Bonding timed out');
        debugPrint('[FrameService] Bonding timed out');
        return false;
      });

      await bondSubscription.cancel();
      return bonded;
    } catch (e) {
      _log.severe('Error during bonding: $e');
      addLogMessage('Error during bonding: $e');
      debugPrint('[FrameService] Error during bonding: $e');
      return false;
    }
  }

  Future<bool> verifyConnection() async {
    if (!_isConnected || _frame == null || _lastConnectedDevice == null) {
      _log.info('Connection invalid: _isConnected=$_isConnected, _frame=${_frame != null}, _lastConnectedDevice=${_lastConnectedDevice != null}');
      return false;
    }
    try {
      final state = await _lastConnectedDevice!.connectionState.first;
      _log.info('Bluetooth connection state: $state');
      if (state != BluetoothConnectionState.connected) {
        _updateConnectionState(false);
        return false;
      }
      String? test = await _frame!.runLua('return "test"').timeout(const Duration(seconds: 5));
      _log.info('Test Lua response: $test');
      return test == '"test"';
    } catch (e) {
      _updateConnectionState(false);
      _log.severe('Connection verification failed: $e');
      addLogMessage('Connection verification failed: $e');
      debugPrint('[FrameService] Connection verification failed: $e');
      return false;
    }
  }

  Future<int?> checkBattery() async {
    if (!_isConnected || _frame == null) {
      _updateConnectionState(false);
      _log.warning('Cannot check battery: Not connected to Frame glasses');
      addLogMessage('Cannot check battery: Not connected');
      debugPrint('[FrameService] Cannot check battery: Not connected');
      return null;
    }

    try {
      _log.info('Checking battery level');
      addLogMessage('Checking battery level');
      debugPrint('[FrameService] Checking battery level');
      String? batteryLevel = await _frame!.runLua('return frame.battery.level()');
      if (batteryLevel == null) {
        _log.warning('Failed to retrieve battery level');
        addLogMessage('Failed to retrieve battery level');
        debugPrint('[FrameService] Failed to retrieve battery level');
        return null;
      }
      int level = int.parse(batteryLevel);
      _log.info('Battery level: $level%');
      addLogMessage('Battery level: $level%');
      debugPrint('[FrameService] Battery level: $level%');
      return level;
    } catch (e) {
      if (e.toString().contains('Not connected')) {
        _updateConnectionState(false);
        _log.severe('Connection lost while checking battery');
        addLogMessage('Connection lost while checking battery');
        debugPrint('[FrameService] Connection lost while checking battery');
        throw Exception('Connection lost while checking battery');
      }
      _log.severe('Error checking battery: $e');
      addLogMessage('Error checking battery: $e');
      debugPrint('[FrameService] Error checking battery: $e');
      return null;
    }
  }

  Future<T> _performOperationWithRetry<T>(Future<T> Function() operation, String operationName) async {
    // Wait until no other operation is running
    while (_isOperationRunning) {
      _log.fine('Waiting for another operation to complete before starting $operationName');
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _isOperationRunning = true;
    try {
      for (int attempt = 1; attempt <= _maxRetries; attempt++) {
        try {
          if (!await verifyConnection()) {
            _log.info('Connection lost, attempting to reconnect for $operationName');
            addLogMessage('Connection lost, attempting to reconnect');
            await connectToGlasses();
            await Future.delayed(const Duration(seconds: 2));
          }
          return await operation().timeout(const Duration(seconds: 30));
        } catch (e) {
          if (e is TimeoutException) {
            _log.severe('$operationName timed out after 30 seconds (attempt $attempt/$_maxRetries)');
            addLogMessage('$operationName timed out');
            if (attempt == _maxRetries) {
              throw Exception('$operationName failed after maximum retries');
            }
            await Future.delayed(Duration(seconds: _retryDelaySeconds));
          } else {
            _log.severe('Error during $operationName: $e');
            addLogMessage('Error during $operationName: $e');
            throw e;
          }
        }
      }
      throw Exception('Operation failed after maximum retries');
    } finally {
      _isOperationRunning = false;
    }
  }

  Future<List<int>> capturePhoto() async {
    return _performOperationWithRetry(() async {
      _log.info('Capturing photo, connection state: $_isConnected');
      addLogMessage('Capturing photo');
      final photoData = await _frame!.camera.takePhoto(
        autofocusSeconds: 1,
        quality: PhotoQuality.medium,
        autofocusType: AutoFocusType.average,
      );
      _log.info('Photo captured successfully, size: ${photoData.length} bytes');
      addLogMessage('Photo captured successfully');
      return photoData;
    }, 'Capturing photo');
  }

  Future<List<String>> listLuaScripts() async {
    return _performOperationWithRetry(() async {
      _log.info('Listing Lua scripts on Frame glasses, connection state: $_isConnected');
      addLogMessage('Listing Lua scripts on Frame glasses');
      String? scriptList = await _frame!.runLua("return frame.app.list()");
      if (scriptList == null || scriptList.isEmpty) {
        _log.info('No Lua scripts found');
        addLogMessage('No Lua scripts found');
        return [];
      }
      List<String> scripts = scriptList.split(',').map((s) => s.trim()).toList();
      _log.info('Retrieved script list: $scripts');
      addLogMessage('Retrieved script list: $scripts');
      return scripts;
    }, 'Listing Lua scripts');
  }

  Future<String?> downloadLuaScript(String scriptName) async {
    return _performOperationWithRetry(() async {
      _log.info('Downloading Lua script: $scriptName, connection state: $_isConnected');
      addLogMessage('Downloading Lua script: $scriptName');
      String? scriptContent = await _frame!.runLua("return frame.storage.read('$scriptName')");
      if (scriptContent == null) {
        _log.warning('Script $scriptName not found');
        addLogMessage('Script $scriptName not found');
        return null;
      }
      _log.info('Downloaded script $scriptName successfully');
      addLogMessage('Downloaded script $scriptName successfully');
      return scriptContent;
    }, 'Downloading Lua script');
  }

  Future<void> uploadLuaScript(String scriptName, String scriptContent) async {
    await _performOperationWithRetry(() async {
      _log.info('Uploading Lua script: $scriptName, connection state: $_isConnected');
      addLogMessage('Uploading Lua script: $scriptName');
      await _frame!.runLua("frame.storage.write('$scriptName', '$scriptContent')");
      _log.info('Uploaded script $scriptName successfully');
      addLogMessage('Uploaded script $scriptName successfully');
      return null;
    }, 'Uploading Lua script');
  }

  void addLogMessage(String message) {
    storageService.saveLog(LogEntry(DateTime.now(), message));
  }

  Future<void> disconnect() async {
    if (!_isConnected || _frame == null) {
      _updateConnectionState(false);
      return;
    }
    try {
      await _frame!.disconnect();
      if (_lastConnectedDevice != null) {
        await _lastConnectedDevice!.disconnect();
      }
      await _stopScan();
      _updateConnectionState(false);
      _frame = null;
      _mtuSet = false;
      _lastConnectedDevice = null;
      _log.info('Disconnected from Frame glasses');
      addLogMessage('Disconnected from Frame glasses');
      debugPrint('[FrameService] Disconnected from Frame glasses');
    } catch (e) {
      _log.severe('Error disconnecting: $e');
      addLogMessage('Error disconnecting: $e');
      debugPrint('[FrameService] Error disconnecting: $e');
    }
  }

  void dispose() {
    _scanSubscription?.cancel();
    _stateSub?.cancel();
    disconnect();
  }
}