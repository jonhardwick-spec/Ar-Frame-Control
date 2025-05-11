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
  frame_sdk.Frame? _frame;
  bool _isConnected = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  final StorageService? storageService;
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 5;
  static const Duration _scanTimeout = Duration(seconds: 15);
  bool _mtuSet = false;
  List<ScanResult> _discoveredDevices = [];

  FrameService({this.storageService}) {
    _log.info('FrameService initialized');
    debugPrint('[FrameService] FrameService initialized');
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
        await Future.delayed(Duration(seconds: 2));
      }
    }

    _log.severe('Failed to get required permissions');
    debugPrint('[FrameService] Failed to get required permissions');
    addLogMessage('Failed to get required permissions');
    return false;
  }

  Future<void> connectToGlasses() async {
    if (_isConnected) {
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
            await Future.delayed(Duration(seconds: _retryDelaySeconds));
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
              await target.device.connect(autoConnect: false, timeout: Duration(seconds: 10));
            }

            bool bonded = await _ensureBonding(target.device);
            if (!bonded) {
              _log.warning('Bonding failed, proceeding without bonding');
              addLogMessage('Bonding failed, proceeding without bonding');
              debugPrint('[FrameService] Bonding failed, proceeding without bonding');
            }

            await Future.delayed(Duration(seconds: 1));
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
                    await Future.delayed(Duration(milliseconds: 500));
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

            _stateSub = target.device.connectionState.listen((state) {
              _log.info('Connection state changed: $state');
              debugPrint('[FrameService] Connection state changed: $state');
              addLogMessage('Connection state changed: $state');
              if (state == BluetoothConnectionState.disconnected) {
                _isConnected = false;
                _frame = null;
                _mtuSet = false;
                _log.severe('Device disconnected unexpectedly');
                addLogMessage('Device disconnected unexpectedly');
                debugPrint('[FrameService] Device disconnected unexpectedly');
              }
            });

            _frame = frame_sdk.Frame();
            await _frame!.connect();
            _isConnected = true;
            _log.info('Successfully connected to Frame glasses');
            addLogMessage('Successfully connected to Frame glasses');
            debugPrint('[FrameService] Successfully connected to Frame glasses');
            break;
          } catch (e) {
            _log.severe('Error connecting to device ${target.device.remoteId}: $e');
            addLogMessage('Error connecting to device ${target.device.remoteId}: $e');
            debugPrint('[FrameService] Error connecting to device ${target.device.remoteId}: $e');
            if (attempt < _maxRetries) {
              _log.info('Retrying in $_retryDelaySeconds seconds...');
              await Future.delayed(Duration(seconds: _retryDelaySeconds));
            } else {
              throw Exception('Connection failed after maximum retries');
            }
          }
        }
      } catch (e) {
        _log.severe('Error during scan and connect: $e');
        addLogMessage('Error during scan and connect: $e');
        debugPrint('[FrameService] Error during scan and connect: $e');
        if (scanAttempt >= 2) {
          throw Exception('Failed to connect: $e');
        }
      }
    }
  }

  Future<void> _scanDevices() async {
    _scanSubscription?.cancel();
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
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
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
      bool bonded = await completer.future.timeout(Duration(seconds: 20), onTimeout: () {
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

  Future<List<int>> capturePhoto() async {
    if (!_isConnected || _frame == null) {
      _log.warning('Cannot capture photo: Not connected to Frame glasses');
      addLogMessage('Cannot capture photo: Not connected');
      debugPrint('[FrameService] Cannot capture photo: Not connected');
      throw Exception('Not connected to Frame glasses');
    }

    try {
      _log.info('Capturing photo');
      addLogMessage('Capturing photo');
      debugPrint('[FrameService] Capturing photo');
      final photoData = await _frame!.camera.takePhoto(
        autofocusSeconds: 1,
        quality: PhotoQuality.full,
        autofocusType: AutoFocusType.average,
      );
      _log.info('Photo captured successfully, size: ${photoData.length} bytes');
      addLogMessage('Photo captured successfully');
      debugPrint('[FrameService] Photo captured successfully, size: ${photoData.length} bytes');
      return photoData;
    } catch (e) {
      _log.severe('Error capturing photo: $e');
      addLogMessage('Error capturing photo: $e');
      debugPrint('[FrameService] Error capturing photo: $e');
      throw Exception('Failed to capture photo: $e');
    }
  }

  Future<List<String>> listLuaScripts() async {
    if (!_isConnected || _frame == null) {
      _log.warning('Cannot list scripts: Not connected to Frame glasses');
      addLogMessage('Cannot list scripts: Not connected');
      debugPrint('[FrameService] Cannot list scripts: Not connected');
      throw Exception('Not connected to Frame glasses');
    }

    try {
      _log.info('Listing Lua scripts on Frame glasses');
      addLogMessage('Listing Lua scripts on Frame glasses');
      debugPrint('[FrameService] Listing Lua scripts on Frame glasses');
      String? scriptList = await _frame!.runLua("return frame.app.list()");
      if (scriptList == null || scriptList.isEmpty) {
        _log.info('No scripts found on Frame glasses');
        addLogMessage('No scripts found on Frame glasses');
        debugPrint('[FrameService] No scripts found on Frame glasses');
        return [];
      }
      List<String> scripts = scriptList.split(',').map((s) => s.trim()).toList();
      _log.info('Retrieved script list: $scripts');
      addLogMessage('Retrieved script list: $scripts');
      debugPrint('[FrameService] Retrieved script list: $scripts');
      return scripts;
    } catch (e) {
      _log.severe('Error listing Lua scripts: $e');
      addLogMessage('Error listing Lua scripts: $e');
      debugPrint('[FrameService] Error listing Lua scripts: $e');
      throw Exception('Failed to list Lua scripts: $e');
    }
  }

  Future<String?> downloadLuaScript(String scriptName) async {
    if (!_isConnected || _frame == null) {
      _log.warning('Cannot download script: Not connected to Frame glasses');
      addLogMessage('Cannot download script: Not connected');
      debugPrint('[FrameService] Cannot download script: Not connected');
      throw Exception('Not connected to Frame glasses');
    }

    try {
      _log.info('Downloading Lua script: $scriptName');
      addLogMessage('Downloading Lua script: $scriptName');
      debugPrint('[FrameService] Downloading Lua script: $scriptName');
      Future<String?> scriptContent = _frame!.runLua("return frame.storage.read('$scriptName')");
      _log.info('Initiated download for script $scriptName');
      addLogMessage('Initiated download for script $scriptName');
      debugPrint('[FrameService] Initiated download for script $scriptName');
      return scriptContent;
    } catch (e) {
      _log.severe('Error downloading Lua script $scriptName: $e');
      addLogMessage('Error downloading Lua script $scriptName: $e');
      debugPrint('[FrameService] Error downloading Lua script $scriptName: $e');
      throw Exception('Failed to download Lua script: $e');
    }
  }

  Future<void> uploadLuaScript(String scriptName, String scriptContent) async {
    if (!_isConnected || _frame == null) {
      _log.warning('Cannot upload script: Not connected to Frame glasses');
      addLogMessage('Cannot upload script: Not connected');
      debugPrint('[FrameService] Cannot upload script: Not connected');
      throw Exception('Not connected to Frame glasses');
    }

    try {
      _log.info('Uploading Lua script: $scriptName');
      addLogMessage('Uploading Lua script: $scriptName');
      debugPrint('[FrameService] Uploading Lua script: $scriptName');
      await _frame!.runLua("frame.storage.write('$scriptName', '$scriptContent')");
      _log.info('Uploaded script $scriptName successfully');
      addLogMessage('Uploaded script $scriptName successfully');
      debugPrint('[FrameService] Uploaded script $scriptName successfully');
    } catch (e) {
      _log.severe('Error uploading Lua script $scriptName: $e');
      addLogMessage('Error uploading Lua script $scriptName: $e');
      debugPrint('[FrameService] Error uploading Lua script $scriptName: $e');
      throw Exception('Failed to upload Lua script: $e');
    }
  }

  Future<void> removeLuaScript(String scriptName) async {
    if (!_isConnected || _frame == null) {
      _log.warning('Cannot remove script: Not connected to Frame glasses');
      addLogMessage('Cannot remove script: Not connected');
      debugPrint('[FrameService] Cannot remove script: Not connected');
      throw Exception('Not connected to Frame glasses');
    }

    try {
      _log.info('Removing Lua script: $scriptName');
      addLogMessage('Removing Lua script: $scriptName');
      debugPrint('[FrameService] Removing Lua script: $scriptName');
      await _frame!.runLua("frame.app.remove('$scriptName')");
      _log.info('Removed script $scriptName successfully');
      addLogMessage('Removed script $scriptName successfully');
      debugPrint('[FrameService] Removed script $scriptName successfully');
    } catch (e) {
      _log.severe('Error removing Lua script $scriptName: $e');
      addLogMessage('Error removing Lua script $scriptName: $e');
      debugPrint('[FrameService] Error removing Lua script $scriptName: $e');
      throw Exception('Failed to remove Lua script: $e');
    }
  }

  void addLogMessage(String message) {
    storageService?.saveLog(LogEntry(DateTime.now(), message));
    debugPrint('[FrameService] $message');
  }

  Future<void> disconnect() async {
    if (!_isConnected) return;
    await _frame?.disconnect();
    if (_discoveredDevices.isNotEmpty) {
      await _discoveredDevices.first.device.disconnect();
    }
    await _stateSub?.cancel();
    _frame = null;
    _isConnected = false;
    _mtuSet = false;
    _log.info('Disconnected from Frame glasses');
    addLogMessage('Disconnected from Frame glasses');
    debugPrint('[FrameService] Disconnected from Frame glasses');
  }

  bool get isConnected => _isConnected;
  frame_sdk.Frame? get frame => _frame;
}