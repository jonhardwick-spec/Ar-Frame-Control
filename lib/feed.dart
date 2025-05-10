import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice, FlutterBluePlus, ScanResult, Guid;
import 'package:frame_sdk/camera.dart';
import 'package:frame_sdk/frame_sdk.dart' as frame_sdk;
import 'package:logging/logging.dart';
import 'package:ar_project/services/storage_service.dart';
import '../models/LogEntry.dart';

class FrameService {
  final Logger _log = Logger('FrameService');
  frame_sdk.Frame? _frame;
  bool _isConnected = false;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  final StorageService? storageService;
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 5;
  static const Duration _scanTimeout = Duration(seconds: 10);

  FrameService({this.storageService}) {
    _log.info('FrameService initialized');
  }

  /// Scans for Frame devices and connects to the first one found
  Future<void> connectToGlasses({String? deviceId}) async {
    if (_isConnected) {
      _log.info('Already connected, skipping connection attempt');
      addLogMessage('Already connected, skipping connection attempt');
      return;
    }

    // If deviceId is provided, connect to that device
    if (deviceId != null) {
      await _connectToDevice(deviceId);
      return;
    }

    // Otherwise, scan for devices
    try {
      _log.info('Scanning for Frame devices');
      addLogMessage('Scanning for Frame devices');
      final devices = <String, BluetoothDevice>{}; // Use a map for unique devices
      _scanSubscription?.cancel(); // Clean up existing subscription
      _scanSubscription = FlutterBluePlus.scanResults.listen(
            (results) {
          for (var result in results) {
            if (result.device.platformName.toLowerCase().contains('frame')) {
              devices[result.device.remoteId.toString()] = result.device;
            }
          }
        },
        onError: (e) {
          _log.severe('Scan error: $e');
        },
      );

      // Start scanning with service filter
      await FlutterBluePlus.startScan(withServices: [Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')]);
      // Wait for scan to complete
      await Future.delayed(_scanTimeout);
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      if (devices.isEmpty) {
        _log.warning('No Frame devices found');
        addLogMessage('No Frame devices found');
        throw Exception('No Frame devices found');
      }

      // Connect to the first Frame device
      final targetDevice = devices.values.first;
      _log.info('Connecting to device: ${targetDevice.platformName} (${targetDevice.remoteId})');
      addLogMessage('Connecting to device: ${targetDevice.platformName} (${targetDevice.remoteId})');
      await _connectToDevice(targetDevice.remoteId.toString());
    } catch (e) {
      _log.severe('Error during scan and connect: $e');
      addLogMessage('Error during scan and connect: $e');
      throw Exception('Failed to connect: $e');
    }
  }

  /// Helper method to connect to a specific device with retry logic
  Future<void> _connectToDevice(String deviceId) async {
    int retries = 0;
    while (retries < _maxRetries && !_isConnected) {
      try {
        _log.info('Attempting to connect to device $deviceId (retry ${retries + 1}/$_maxRetries)');
        // Find the device by ID
        final connectedDevices = await FlutterBluePlus.connectedDevices;
        var device = connectedDevices.firstWhere(
              (d) => d.remoteId.toString() == deviceId,
          orElse: () => throw Exception('Device $deviceId not found'),
        );

        // If not connected, scan for the device
        if (!connectedDevices.any((d) => d.remoteId.toString() == deviceId)) {
          final scanResults = <String, BluetoothDevice>{};
          _scanSubscription = FlutterBluePlus.scanResults.listen(
                (results) {
              for (var result in results) {
                if (result.device.remoteId.toString() == deviceId) {
                  scanResults[result.device.remoteId.toString()] = result.device;
                }
              }
            },
            onError: (e) {
              _log.severe('Scan error: $e');
            },
          );

          await FlutterBluePlus.startScan(withServices: [Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')]);
          await Future.delayed(_scanTimeout);
          await FlutterBluePlus.stopScan();
          await _scanSubscription?.cancel();
          _scanSubscription = null;

          if (scanResults.isEmpty) {
            throw Exception('Device $deviceId not found');
          }
          device = scanResults.values.first;
        }

        // Connect the device first
        await device.connect();
        _frame = frame_sdk.Frame(); // Initialize Frame
        await _frame!.connect(); // Connect using Frame SDK
        _isConnected = true;
        _log.info('Connected to Frame glasses');
        addLogMessage('Connected to Frame glasses');
      } catch (e) {
        _log.severe('Error connecting to device $deviceId: $e');
        retries++;
        if (retries < _maxRetries) {
          _log.info('Retrying in $_retryDelaySeconds seconds...');
          await Future.delayed(Duration(seconds: _retryDelaySeconds));
        } else {
          _log.severe('Failed to connect after $_maxRetries retries');
          addLogMessage('Failed to connect to Frame glasses after $_maxRetries retries');
          throw Exception('Connection failed after maximum retries');
        }
      } finally {
        // Clean up if not connected
        if (!_isConnected) {
          _frame = null;
          await Future.delayed(const Duration(milliseconds: 500)); // Allow GC
        }
      }
    }
  }

  /// Captures a photo using the Frame glasses
  Future<List<int>> capturePhoto() async {
    if (!_isConnected || _frame == null) {
      _log.warning('Cannot capture photo: Not connected to Frame glasses');
      addLogMessage('Cannot capture photo: Not connected');
      throw Exception('Not connected to Frame glasses');
    }

    try {
      _log.info('Capturing photo');
      addLogMessage('Capturing photo');
      final photoData = await _frame!.camera.takePhoto(autofocusSeconds: 1, quality: PhotoQuality.full, autofocusType: AutoFocusType.average);
      _log.info('Photo captured successfully, size: ${photoData.length} bytes');
      addLogMessage('Photo captured successfully');
      return photoData;
    } catch (e) {
      _log.severe('Error capturing photo: $e');
      addLogMessage('Error capturing photo: $e');
      throw Exception('Failed to capture photo: $e');
    }
  }

  void addLogMessage(String message) {
    storageService?.saveLog(LogEntry(DateTime.now(), message
    ));
  }

  Future<void> disconnect() async {
    if (_isConnected) {
      await _frame?.disconnect();
      _frame = null;
      _isConnected = false;
      _log.info('Disconnected from Frame glasses');
      addLogMessage('Disconnected from Frame glasses');
    }
  }

  bool get isConnected => _isConnected;
  frame_sdk.Frame? get frame => _frame;
}