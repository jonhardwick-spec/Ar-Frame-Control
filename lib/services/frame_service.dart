import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;
import 'package:frame_sdk/frame_sdk.dart' as frame_sdk;
import 'package:frame_sdk/bluetooth.dart' as frame_sdk_ble;
import 'package:frame_ble/frame_ble.dart' as frame_ble;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ar_project/models/log_entry.dart';
import 'package:ar_project/services/storage_service.dart';

class FrameService {
  final Logger _log = Logger('FrameService');
  frame_sdk_ble.BrilliantDevice? _device;
  frame_sdk.Frame? _frame;
  bool _isConnected = false;
  final StorageService? storageService;
  static const int _maxRetries = 5;

  FrameService({this.storageService}) {
    _log.info('frame service constructor called');
  }

  Future<bool> _checkPermissions() async {
    var statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    bool granted = statuses.values.every((status) => status.isGranted);
    if (!granted) {
      _log.severe('Bluetooth permissions not granted');
      await addLogMessage('Bluetooth permissions not granted');
    }
    return granted;
  }

  Future<bool> _waitForBonding(frame_sdk_ble.BrilliantScannedDevice scannedFrame) async {
    int bondRetries = 0;
    const int maxBondRetries = 10;
    while (bondRetries < maxBondRetries) {
      try {
        // Check if the device is bonded (this is a placeholder; frame_sdk might have a specific method)
        if (scannedFrame.device.bondState.isBroadcast) {
          _log.info('Device bonding completed');
          return true;
        }
        _log.info('Waiting for bonding to complete... (Attempt ${bondRetries + 1}/$maxBondRetries)');
        await Future.delayed(const Duration(seconds: 1));
        bondRetries++;
      } catch (e) {
        _log.warning('Error checking bonding state: $e');
        await Future.delayed(const Duration(seconds: 1));
        bondRetries++;
      }
    }
    _log.severe('Bonding failed after $maxBondRetries attempts');
    return false;
  }

  Future<void> connectToGlasses() async {
    if (_isConnected) {
      _log.info('already connected, skipping connection attempt');
      return;
    }

    if (!(await _checkPermissions())) {
      throw Exception('Bluetooth permissions required');
    }

    int retries = 0;
    while (retries < _maxRetries && !_isConnected) {
      try {
        _log.info('Attempting to connect to Frame glasses (Retry ${retries + 1}/$_maxRetries)');

        // Scan for Frame device with timeout
        frame_sdk_ble.BrilliantScannedDevice? scannedFrame;
        try {
          _log.info('starting bluetooth scan...');
          await for (var device in frame_sdk_ble.BrilliantBluetooth.scan().timeout(
            const Duration(seconds: 10),
            onTimeout: (sink) {
              sink.addError(TimeoutException('Bluetooth scan timed out after 10 seconds'));
            },
          )) {
            final deviceName = device.device.platformName ?? 'Unknown';
            final deviceId = device.device.remoteId ?? 'Unknown';
            _log.info('Found device: $deviceName, ID: $deviceId');
            if (deviceName.toLowerCase().contains('frame')) {
              scannedFrame = device;
              _log.info('selected Frame device: $deviceName, ID: $deviceId');
              break;
            }
          }
          if (scannedFrame == null) {
            throw Exception('No Frame device found during scan');
          }
        } catch (e) {
          _log.severe('Error scanning for Frame: $e');
          retries++;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        // Wait for bonding to complete
        if (!(await _waitForBonding(scannedFrame))) {
          _log.severe('Failed to bond with device');
          retries++;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        // Connect to the scanned Frame
        try {
          _log.info('attempting to connect to device: ${scannedFrame.device.platformName}, ID: ${scannedFrame.device.remoteId}');
          _device = await frame_sdk_ble.BrilliantBluetooth.connect(scannedFrame).timeout(
            const Duration(seconds: 20), // Increased timeout to 20 seconds
            onTimeout: () => Future.error(TimeoutException('Bluetooth connection timed out after 20 seconds')),
          );
          _frame = frame_sdk.Frame(); // Adjust if device parameter is needed
          _isConnected = true;
          _log.info('Connected to Frame glasses');
          await addLogMessage('Connected to Frame glasses');
        } catch (e) {
          _log.severe('Error connecting to Frame: $e');
          retries++;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
      } catch (e) {
        _log.severe('Unexpected error during connection process: $e');
        retries++;
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    if (!_isConnected) {
      _log.severe('Failed to connect to Frame glasses after $_maxRetries retries');
      await addLogMessage('Failed to connect to Frame glasses after $_maxRetries retries');
      throw Exception('Connection failed after maximum retries');
    }
  }

  // Fallback method using frame_ble for low-level BLE connection
  Future<void> connectToGlassesWithFrameBle() async {
    if (_isConnected) {
      _log.info('already connected, skipping connection attempt');
      return;
    }

    if (!(await _checkPermissions())) {
      throw Exception('Bluetooth permissions required');
    }

    try {
      _log.info('attempting to connect using frame_ble...');
      dynamic scannedFrame; // Use dynamic to handle potential type mismatch
      await for (var device in frame_ble.BrilliantBluetooth.scan().timeout(
        const Duration(seconds: 10),
        onTimeout: (sink) {
          sink.addError(TimeoutException('Bluetooth scan timed out after 10 seconds'));
        },
      )) {
        final deviceName = device.device.platformName ?? 'Unknown';
        final deviceId = device.device.remoteId ?? 'Unknown';
        _log.info('Found device: $deviceName, ID: $deviceId');
        if (deviceName.toLowerCase().contains('frame')) {
          scannedFrame = device;
          _log.info('selected Frame device: $deviceName, ID: $deviceId');
          break;
        }
      }
      if (scannedFrame == null) {
        throw Exception('No Frame device found during scan');
      }

      // Connect using frame_ble
      _log.info('connecting to device: ${scannedFrame.device.platformName}, ID: ${scannedFrame.device.remoteId}');
      final connectedDevice = await frame_ble.BrilliantBluetooth.connect(scannedFrame).timeout(const Duration(seconds: 20));
      _frame = frame_sdk.Frame(); // Adjust if device parameter is needed
      _isConnected = true;
      _log.info('Connected to Frame glasses using frame_ble');
      await addLogMessage('Connected to Frame glasses using frame_ble');
    } catch (e) {
      _log.severe('Error connecting with frame_ble: $e');
      await addLogMessage('Error connecting with frame_ble: $e');
      throw Exception('Failed to connect using frame_ble: $e');
    }
  }

  Future<List<int>?> capturePhoto() async {
    if (!_isConnected) {
      _log.warning('cannot capture photo, not connected');
      await addLogMessage('Cannot capture photo: not connected');
      return null;
    }
    try {
      _log.info('attempting to capture photo');
      final photo = await _frame!.camera.takePhoto();
      if (photo != null && photo.isNotEmpty) {
        _log.info('photo captured, length: ${photo.length}');
        await addLogMessage('Photo captured, length: ${photo.length}');
        return photo;
      } else {
        _log.warning('no photo data received');
        await addLogMessage('No photo data received');
        return null;
      }
    } catch (e) {
      _log.severe('error capturing photo: $e');
      await addLogMessage('Error capturing photo: $e');
      return null;
    }
  }

  Future<String?> getDisplayText() async {
    if (!_isConnected) {
      _log.warning('cannot get display text, not connected');
      await addLogMessage('Cannot get display text: not connected');
      return null;
    }
    try {
      _log.info('fetching display text');
      final text = await _frame!.display.toString();
      _log.info('display text fetched: $text');
      await addLogMessage('Display text fetched: $text');
      return text;
    } catch (e) {
      _log.severe('error getting display text: $e');
      await addLogMessage('Error getting display text: $e');
      return null;
    }
  }

  Future<void> uploadLuaScript(String fileName) async {
    if (!_isConnected) {
      _log.warning('cannot upload script, not connected');
      await addLogMessage('Cannot upload script: not connected');
      return;
    }
    try {
      _log.info('uploading lua script: $fileName');
      final script = await rootBundle.loadString('assets/lua/$fileName');
      final luaCommand = 'frame.filesystem.write("$fileName", [[$script]])';
      await _frame!.runLua(luaCommand);
      _log.info('lua script $fileName uploaded');
      await addLogMessage('Lua script $fileName uploaded');
    } catch (e) {
      _log.severe('error uploading lua script: $e');
      await addLogMessage('Error uploading lua script: $e');
      rethrow;
    }
  }

  Future<void> addLogMessage(String message) async {
    if (storageService == null) return;
    try {
      _log.info('adding log message: $message');
      final logEntry = LogEntry(
        timestamp: DateTime.now().toIso8601String(),
        message: message,
      );
      await storageService!.saveLog(logEntry);
    } catch (e) {
      // Suppress BroadcastStreamController errors
      _log.warning('Error logging message: $e');
    }
  }

  Future<void> disconnect() async {
    if (!_isConnected) return;
    try {
      _log.info('disconnecting from frame glasses');
      await _frame!.disconnect();
      _isConnected = false;
      _frame = null;
      _log.info('disconnected from frame glasses');
      await addLogMessage('Disconnected from Frame glasses');
    } catch (e) {
      _log.severe('error disconnecting: $e');
      await addLogMessage('Error disconnecting: $e');
    }
  }

  bool get isConnected => _isConnected;
  frame_sdk.Frame? get frame => _frame;
}