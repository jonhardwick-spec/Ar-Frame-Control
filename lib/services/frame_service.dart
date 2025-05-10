import 'dart:async';
import 'dart:io';
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
  static const int _connectTimeoutSeconds = 20;

  FrameService({this.storageService}) {
    _log.info('frame service constructor called');
    print('FrameService initialized'); // Fallback for debugging
  }

  Future<bool> _checkPermissions() async {
    var statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    bool granted = statuses.values.every((status) => status.isGranted);
    if (!granted) {
      _log.severe('bluetooth permissions not granted');
      print('Bluetooth permissions not granted'); // Fallback
      await addLogMessage('Bluetooth permissions not granted');
    }
    return granted;
  }

  Future<void> connectToGlasses() async {
    if (_isConnected) {
      _log.info('already connected, skipping connection attempt');
      print('Already connected, skipping'); // Fallback
      return;
    }

    if (!(await _checkPermissions())) {
      throw Exception('Bluetooth permissions required');
    }

    int retries = 0;
    while (retries < _maxRetries && !_isConnected) {
      try {
        _log.info('attempting to connect to frame glasses (retry ${retries + 1}/$_maxRetries)');
        print('Connecting to Frame, retry ${retries + 1}/$_maxRetries'); // Fallback

        // Scan for Frame device
        frame_sdk_ble.BrilliantScannedDevice? scannedFrame;
        try {
          _log.info('starting bluetooth scan...');
          print('Starting Bluetooth scan'); // Fallback
          await for (var device in frame_sdk_ble.BrilliantBluetooth.scan().timeout(
            const Duration(seconds: 10),
            onTimeout: (sink) {
              sink.addError(TimeoutException('bluetooth scan timed out after 10 seconds'));
            },
          )) {
            final deviceName = device.device.platformName ?? 'unknown';
            final deviceId = device.device.remoteId ?? 'unknown';
            _log.info('found device: $deviceName, id: $deviceId');
            print('Found device: $deviceName, id: $deviceId'); // Fallback
            if (deviceName.toLowerCase().contains('frame')) {
              scannedFrame = device;
              _log.info('selected frame device: $deviceName, id: $deviceId');
              print('Selected Frame device: $deviceName, id: $deviceId'); // Fallback
              break;
            }
          }
          if (scannedFrame == null) {
            throw Exception('no frame device found during scan');
          }
        } catch (e) {
          _log.severe('error scanning for frame: $e');
          print('Scan error: $e'); // Fallback
          retries++;
          await Future.delayed(Duration(seconds: 2 * (retries + 1)));
          continue;
        }

        // Wait for Bluetooth stack stability
        _log.info('waiting for device stability...');
        print('Waiting for device stability'); // Fallback
        await Future.delayed(const Duration(seconds: 2));

        // Connect to the scanned Frame
        try {
          _log.info('attempting to connect to device: ${scannedFrame.device.platformName}, id: ${scannedFrame.device.remoteId}');
          print('Connecting to device: ${scannedFrame.device.platformName}, id: ${scannedFrame.device.remoteId}'); // Fallback
          _device = await frame_sdk_ble.BrilliantBluetooth.connect(scannedFrame).timeout(
            const Duration(seconds: _connectTimeoutSeconds),
            onTimeout: () => Future.error(TimeoutException('bluetooth connection timed out after $_connectTimeoutSeconds seconds')),
          );
          _frame = frame_sdk.Frame();
          _isConnected = true;
          _log.info('connected to frame glasses');
          print('Connected to Frame glasses'); // Fallback
          await addLogMessage('Connected to Frame glasses');
        } catch (e) {
          _log.severe('error connecting to frame: $e');
          print('Connection error: $e'); // Fallback
          retries++;
          await Future.delayed(Duration(seconds: 2 * (retries + 1)));
          continue;
        }
      } catch (e) {
        _log.severe('unexpected error during connection process: $e');
        print('Unexpected error: $e'); // Fallback
        retries++;
        await Future.delayed(Duration(seconds: 2 * (retries + 1)));
      }
    }

    if (!_isConnected) {
      _log.severe('failed to connect to frame glasses after $_maxRetries retries');
      print('Failed to connect after $_maxRetries retries'); // Fallback
      await addLogMessage('Failed to connect to Frame glasses after $_maxRetries retries');
      throw Exception('connection failed after maximum retries');
    }
  }

  Future<void> connectToGlassesWithFrameBle() async {
    if (_isConnected) {
      _log.info('already connected, skipping connection attempt');
      print('Already connected, skipping'); // Fallback
      return;
    }

    if (!(await _checkPermissions())) {
      throw Exception('Bluetooth permissions required');
    }

    try {
      _log.info('attempting to connect using frame_ble...');
      print('Connecting using frame_ble'); // Fallback
      dynamic scannedFrame;
      await for (var device in frame_ble.BrilliantBluetooth.scan().timeout(
        const Duration(seconds: 10),
        onTimeout: (sink) {
          sink.addError(TimeoutException('bluetooth scan timed out after 10 seconds'));
        },
      )) {
        final deviceName = device.device.platformName ?? 'unknown';
        final deviceId = device.device.remoteId ?? 'unknown';
        _log.info('found device: $deviceName, id: $deviceId');
        print('Found device: $deviceName, id: $deviceId'); // Fallback
        if (deviceName.toLowerCase().contains('frame')) {
          scannedFrame = device;
          _log.info('selected frame device: $deviceName, id: $deviceId');
          print('Selected Frame device: $deviceName, id: $deviceId'); // Fallback
          break;
        }
      }
      if (scannedFrame == null) {
        throw Exception('no frame device found during scan');
      }

      _log.info('waiting for device stability...');
      print('Waiting for device stability'); // Fallback
      await Future.delayed(const Duration(seconds: 2));

      _log.info('connecting to device: ${scannedFrame.device.platformName}, id: ${scannedFrame.device.remoteId}');
      print('Connecting to device: ${scannedFrame.device.platformName}, id: ${scannedFrame.device.remoteId}'); // Fallback
      final connectedDevice = await frame_ble.BrilliantBluetooth.connect(scannedFrame).timeout(
        const Duration(seconds: _connectTimeoutSeconds),
        onTimeout: () => Future.error(TimeoutException('bluetooth connection timed out after $_connectTimeoutSeconds seconds')),
      );
      _frame = frame_sdk.Frame();
      _isConnected = true;
      _log.info('connected to frame glasses using frame_ble');
      print('Connected to Frame glasses using frame_ble'); // Fallback
      await addLogMessage('Connected to Frame glasses using frame_ble');
    } catch (e) {
      _log.severe('error connecting with frame_ble: $e');
      print('FrameBle connection error: $e'); // Fallback
      await addLogMessage('Error connecting with frame_ble: $e');
      throw Exception('failed to connect using frame_ble: $e');
    }
  }

  Future<List<int>?> capturePhoto() async {
    if (!_isConnected) {
      _log.warning('cannot capture photo, not connected');
      print('Cannot capture photo: not connected'); // Fallback
      await addLogMessage('Cannot capture photo: not connected');
      return null;
    }
    try {
      _log.info('attempting to capture photo');
      print('Capturing photo'); // Fallback
      final photo = await _frame!.camera.takePhoto();
      if (photo != null && photo.isNotEmpty) {
        _log.info('photo captured, length: ${photo.length}');
        print('Photo captured, length: ${photo.length}'); // Fallback
        await addLogMessage('Photo captured, length: ${photo.length}');
        return photo;
      } else {
        _log.warning('no photo data received');
        print('No photo data received'); // Fallback
        await addLogMessage('No photo data received');
        return null;
      }
    } catch (e) {
      _log.severe('error capturing photo: $e');
      print('Photo capture error: $e'); // Fallback
      await addLogMessage('Error capturing photo: $e');
      return null;
    }
  }

  Future<String?> getDisplayText() async {
    if (!_isConnected) {
      _log.warning('cannot get display text, not connected');
      print('Cannot get display text: not connected'); // Fallback
      await addLogMessage('Cannot get display text: not connected');
      return null;
    }
    try {
      _log.info('fetching display text');
      print('Fetching display text'); // Fallback
      final text = await _frame!.display.toString();
      _log.info('display text fetched: $text');
      print('Display text fetched: $text'); // Fallback
      await addLogMessage('Display text fetched: $text');
      return text;
    } catch (e) {
      _log.severe('error getting display text: $e');
      print('Display text error: $e'); // Fallback
      await addLogMessage('Error getting display text: $e');
      return null;
    }
  }

  Future<void> uploadLuaScript(String fileName) async {
    if (!_isConnected) {
      _log.warning('cannot upload script, not connected');
      print('Cannot upload script: not connected'); // Fallback
      await addLogMessage('Cannot upload script: not connected');
      return;
    }
    try {
      _log.info('uploading lua script: $fileName');
      print('Uploading Lua script: $fileName'); // Fallback
      final script = await rootBundle.loadString('assets/lua/$fileName');
      final luaCommand = 'frame.filesystem.write("$fileName", [[$script]])';
      await _frame!.runLua(luaCommand);
      _log.info('lua script $fileName uploaded');
      print('Lua script $fileName uploaded'); // Fallback
      await addLogMessage('Lua script $fileName uploaded');
    } catch (e) {
      _log.severe('error uploading lua script: $e');
      print('Lua script upload error: $e'); // Fallback
      await addLogMessage('Error uploading lua script: $e');
      rethrow;
    }
  }

  Future<void> addLogMessage(String message) async {
    if (storageService == null) return;
    try {
      _log.info('adding log message: $message');
      print('Adding log message: $message'); // Fallback
      final logEntry = LogEntry(
        timestamp: DateTime.now().toIso8601String(),
        message: message,
      );
      await storageService!.saveLog(logEntry);
    } catch (e) {
      _log.warning('error logging message: $e');
      print('Log message error: $e'); // Fallback
    }
  }

  Future<void> disconnect() async {
    if (!_isConnected) return;
    try {
      _log.info('disconnecting from frame glasses');
      print('Disconnecting from Frame glasses'); // Fallback
      await _frame!.disconnect();
      _isConnected = false;
      _frame = null;
      _device = null;
      _log.info('disconnected from frame glasses');
      print('Disconnected from Frame glasses'); // Fallback
      await addLogMessage('Disconnected from Frame glasses');
    } catch (e) {
      _log.severe('error disconnecting: $e');
      print('Disconnect error: $e'); // Fallback
      await addLogMessage('Error disconnecting: $e');
    }
  }

  bool get isConnected => _isConnected;
  frame_sdk.Frame? get frame => _frame;
}