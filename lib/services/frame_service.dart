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
  final StorageService? storageService;
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 5;
  static const Duration _scanTimeout = Duration(seconds: 15);
  bool _mtuSet = false; // Track MTU status

  List<ScanResult> _discoveredDevices = [];

  FrameService({this.storageService}) {
    _log.info('FrameService initialized');
    debugPrint('[FrameService] FrameService initialized');
  }

  Future<bool> initialize() async {
    debugPrint('[FrameService] Initializing Bluetooth...');

    bool isLocationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isLocationServiceEnabled) {
      _log.warning('Location services are disabled');
      debugPrint('[FrameService] Location services are disabled');
      addLogMessage('Please enable location services to connect to Frame glasses');
      await Geolocator.openLocationSettings();
      isLocationServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isLocationServiceEnabled) {
        _log.severe('Location services not enabled');
        debugPrint('[FrameService] Location services not enabled');
        addLogMessage('Location services required for Bluetooth scanning');
        return false;
      }
    }

    int permissionAttempts = 0;
    const maxPermissionAttempts = 2;
    Map<Permission, PermissionStatus> statuses = {};
    while (permissionAttempts < maxPermissionAttempts) {
      statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      bool permissionsGranted = statuses.values.every((status) => status.isGranted);
      if (permissionsGranted) {
        debugPrint('[FrameService] All permissions granted');
        return true;
      }

      permissionAttempts++;
      _log.warning('Permissions not granted: $statuses');
      debugPrint('[FrameService] Permissions not granted: $statuses');
      addLogMessage('Please grant all permissions to connect to Frame glasses');

      if (permissionAttempts < maxPermissionAttempts) {
        _log.info('Retrying permission request in 2 seconds...');
        await Future.delayed(Duration(seconds: 2));
      }
    }

    _log.severe('Failed to get required permissions: $statuses');
    debugPrint('[FrameService] Failed to get required permissions: $statuses');
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

    int scanAttempts = 0;
    const maxScanAttempts = 2;
    while (scanAttempts < maxScanAttempts && !_isConnected) {
      scanAttempts++;
      _log.info('Scanning for Frame devices (attempt $scanAttempts/$maxScanAttempts)');
      addLogMessage('Scanning for Frame devices (attempt $scanAttempts/$maxScanAttempts)');
      debugPrint('[FrameService] Scanning for Frame devices (attempt $scanAttempts/$maxScanAttempts)');

      try {
        _discoveredDevices.clear();
        _scanSubscription?.cancel();
        _scanSubscription = FlutterBluePlus.scanResults.listen(
              (results) {
            for (var result in results) {
              if (result.advertisementData.serviceUuids.contains(Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')) ||
                  result.advertisementData.serviceUuids.contains(Guid('fe59'))) {
                if (!_discoveredDevices.any((d) => d.device.remoteId == result.device.remoteId)) {
                  _discoveredDevices.add(result);
                  _log.fine('Found Frame device: ${result.device.platformName} (${result.device.remoteId}), RSSI: ${result.rssi}');
                  debugPrint('[FrameService] Found Frame device: ${result.device.platformName} (${result.device.remoteId}), RSSI: ${result.rssi}');
                }
              }
            }
          },
          onError: (e) {
            _log.severe('Scan error: $e');
            addLogMessage('Scan error: $e');
            debugPrint('[FrameService] Scan error: $e');
          },
        );

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

        if (_discoveredDevices.isEmpty) {
          _log.warning('No Frame devices found in scan attempt $scanAttempts');
          addLogMessage('No Frame devices found in scan attempt $scanAttempts');
          debugPrint('[FrameService] No Frame devices found in scan attempt $scanAttempts');
          if (scanAttempts < maxScanAttempts) {
            _log.info('Retrying scan in $_retryDelaySeconds seconds...');
            await Future.delayed(Duration(seconds: _retryDelaySeconds));
            continue;
          }
          throw Exception('No Frame devices found after $maxScanAttempts attempts');
        }

        _log.info('Found ${_discoveredDevices.length} Frame devices: ${_discoveredDevices.map((d) => "${d.device.platformName} (${d.device.remoteId})").join(", ")}');
        addLogMessage('Found ${_discoveredDevices.length} Frame devices');
        debugPrint('[FrameService] Found ${_discoveredDevices.length} Frame devices');

        final targetDevice = _discoveredDevices.firstWhere((d) => d.rssi >= -80, orElse: () => throw Exception('No Frame device with sufficient signal strength (min RSSI: -80)'));
        _log.info('Selected device: ${targetDevice.device.platformName} (${targetDevice.device.remoteId}), RSSI: ${targetDevice.rssi}');
        addLogMessage('Selected device: ${targetDevice.device.platformName} (${targetDevice.device.remoteId})');
        debugPrint('[FrameService] Selected device: ${targetDevice.device.platformName} (${targetDevice.device.remoteId}), RSSI: ${targetDevice.rssi}');

        int retries = 0;
        while (retries < _maxRetries && !_isConnected) {
          try {
            _log.info('Attempting to connect to device ${targetDevice.device.remoteId} (retry ${retries + 1}/$_maxRetries)');
            addLogMessage('Attempting to connect to device ${targetDevice.device.remoteId} (retry ${retries + 1}/$_maxRetries)');
            debugPrint('[FrameService] Attempting to connect to device ${targetDevice.device.remoteId} (retry ${retries + 1}/$_maxRetries)');

            StreamSubscription<BluetoothConnectionState>? stateSubscription;
            stateSubscription = targetDevice.device.state.listen((state) async {
              if (state == BluetoothDeviceState.connected) {
                _log.info('[FrameService] Connected to Frame glasses');
                addLogMessage('Connected to Frame glasses');
                debugPrint('[FrameService] Connected to Frame glasses');
              } else if (state == BluetoothDeviceState.disconnected) {
                _log.info('[FrameService] Device disconnected, attempting reconnect...');
                addLogMessage('Device disconnected, attempting reconnect...');
                debugPrint('[FrameService] Device disconnected, attempting reconnect...');
                await targetDevice.device.connect(autoConnect: false, timeout: Duration(seconds: 10));
              }
            });

            await targetDevice.device.connect(autoConnect: false, timeout: Duration(seconds: 10));
            bool bonded = await _ensureBonding(targetDevice.device);
            if (!bonded) {
              _log.warning('[FrameService] Bonding failed, proceeding without bonding');
              addLogMessage('Bonding failed, proceeding without bonding');
              debugPrint('[FrameService] Bonding failed, proceeding without bonding');
            }

            await Future.delayed(Duration(seconds: 1)); // Stabilize connection before MTU

            if (!_mtuSet) {
              _log.info('[FrameService] Configuring MTU to 247...');
              addLogMessage('Configuring MTU to 247...');
              debugPrint('[FrameService] Configuring MTU to 247...');
              int mtu = await targetDevice.device.requestMtu(247);
              _log.info('[FrameService] MTU set to $mtu');
              addLogMessage('MTU set to $mtu');
              debugPrint('[FrameService] MTU set to $mtu');
              _mtuSet = true;
            }

            if (await targetDevice.device.state.first == BluetoothDeviceState.connected) {
              _log.info('[FrameService] Discovering services...');
              addLogMessage('Discovering services...');
              debugPrint('[FrameService] Discovering services...');
              await targetDevice.device.discoverServices();
              _log.info('[FrameService] Services discovered');
              addLogMessage('Services discovered');
              debugPrint('[FrameService] Services discovered');
            } else {
              _log.warning('[FrameService] Cannot discover services, device not connected');
              addLogMessage('Cannot discover services, device not connected');
              debugPrint('[FrameService] Cannot discover services, device not connected');
              throw Exception('Device disconnected during setup');
            }

            _isConnected = true;
            _frame = frame_sdk.Frame();
            await _frame!.connect();
            await stateSubscription.cancel();
            break;
          } catch (e) {
            _log.severe('Error connecting to device ${targetDevice.device.remoteId}: $e');
            addLogMessage('Error connecting to device ${targetDevice.device.remoteId}: $e');
            debugPrint('[FrameService] Error connecting to device ${targetDevice.device.remoteId}: $e');
            retries++;
            if (retries < _maxRetries) {
              _log.info('Retrying in $_retryDelaySeconds seconds...');
              await Future.delayed(Duration(seconds: _retryDelaySeconds));
            } else {
              _log.severe('Failed to connect after $_maxRetries retries');
              addLogMessage('Failed to connect to Frame glasses after $_maxRetries retries');
              throw Exception('Connection failed after maximum retries');
            }
          }
        }
      } catch (e) {
        _log.severe('Error during scan and connect: $e');
        addLogMessage('Error during scan and connect: $e');
        debugPrint('[FrameService] Error during scan and connect: $e');
        if (scanAttempts >= maxScanAttempts) {
          throw Exception('Failed to connect: $e');
        }
      }
    }
  }

  Future<bool> _ensureBonding(BluetoothDevice device) async {
    try {
      var bondCompleter = Completer<bool>();
      StreamSubscription<BluetoothBondState>? bondSubscription;

      bondSubscription = device.bondState.listen((state) {
        _log.info('[FrameService] Bond state changed: $state');
        addLogMessage('Bond state changed: $state');
        debugPrint('[FrameService] Bond state changed: $state');
        if (state == BluetoothBondState.bonded) {
          _log.info('[FrameService] Bonding complete');
          addLogMessage('Bonding complete');
          debugPrint('[FrameService] Bonding complete');
          bondCompleter.complete(true);
        } else if (state == BluetoothBondState.none) {
          _log.warning('[FrameService] Bonding failed or not bonded');
          addLogMessage('Bonding failed or not bonded');
          debugPrint('[FrameService] Bonding failed or not bonded');
          bondCompleter.complete(false);
        }
      });

      await device.createBond();
      bool bonded = await bondCompleter.future.timeout(Duration(seconds: 20), onTimeout: () {
        _log.warning('[FrameService] Bonding timed out');
        addLogMessage('Bonding timed out');
        debugPrint('[FrameService] Bonding timed out');
        return false;
      });

      await bondSubscription.cancel();
      return bonded;
    } catch (e) {
      _log.severe('[FrameService] Error during bonding: $e');
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

  void addLogMessage(String message) {
    storageService?.saveLog(LogEntry(DateTime.now(), message));
    debugPrint('[FrameService] $message');
  }

  Future<void> disconnect() async {
    if (_isConnected) {
      await _frame?.disconnect();
      if (_discoveredDevices.isNotEmpty) {
        await _discoveredDevices.first.device.disconnect();
      }
      _frame = null;
      _isConnected = false;
      _mtuSet = false; // Reset MTU flag on disconnect
      _log.info('Disconnected from Frame glasses');
      addLogMessage('Disconnected from Frame glasses');
      debugPrint('[FrameService] Disconnected from Frame glasses');
    }
  }

  bool get isConnected => _isConnected;
  frame_sdk.Frame? get frame => _frame;
}