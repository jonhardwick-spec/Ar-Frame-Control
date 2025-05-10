import 'dart:async';
import 'package:frame_ble/frame_ble.dart';
import 'package:logging/logging.dart';

import '../services/storage_service.dart';
import 'LogEntry.dart';
class FrameService {
  final StorageService storageService;
  final Logger _logger = Logger('FrameService');
  BrilliantDevice? _device;

  FrameService(this.storageService);

  Future<bool> connectToGlasses({int retryCount = 5}) async {
    for (var attempt = 1; attempt <= retryCount; attempt++) {
      try {
        _logger.info('Attempting to connect to Frame glasses (retry $attempt/$retryCount)');
        final stream = BrilliantBluetooth.scan();
        final scannedDevice = await stream.firstWhere(
              (d) => d.device.advName.contains('Frame'),
        ).timeout(const Duration(seconds: 15), onTimeout: () async {
          _logger.warning('Bluetooth scan timed out after 15 seconds');
          await BrilliantBluetooth.stopScan();
          throw TimeoutException('Bluetooth scan timed out after 15 seconds');
        });

        if (scannedDevice.toString().length > 1) {
          _logger.warning('No Frame device found');
          continue;
        }

        _logger.info('Attempting to connect to device: ${scannedDevice.device.name}, id: ${scannedDevice.device.remoteId}');
        _device = await BrilliantBluetooth.connect(scannedDevice).timeout(const Duration(seconds: 10));
        if (_device != null) {
          _logger.info('Connected to Frame');
          return true;
        } else {
          _logger.warning('Failed to connect');
        }
      } catch (e) {
        _logger.severe('Error connecting to Frame: $e');
        await addLogMessage('Error connecting to Frame: $e');
        if (attempt == retryCount) {
          _logger.severe('Failed to connect after $retryCount attempts');
          return false;
        }
      }
    }
    return false;
  }

  Future<void> addLogMessage(String message) async {
    await storageService.saveLog(LogEntry(DateTime.now(), message));
  }

  bool get isConnected => _device != null;

  Future<String> getDisplayText() async {
    if (_device == null) throw Exception('Not connected');
    try {
      // Placeholder: Implement BLE characteristic read for display text
      return 'Placeholder display text';
    } catch (e) {
      _logger.severe('Error getting display text: $e');
      await addLogMessage('Error getting display text: $e');
      rethrow;
    }
  }

  Future<List<int>> capturePhoto() async {
    if (_device == null) throw Exception('Not connected');
    try {
      // Placeholder: Implement BLE characteristic write for photo capture
      return [];
    } catch (e) {
      _logger.severe('Error capturing photo: $e');
      await addLogMessage('Error capturing photo: $e');
      rethrow;
    }
  }

  Future<void> uploadLuaScript(String script) async {
    if (_device == null) throw Exception('Not connected');
    try {
      // Placeholder: Implement BLE characteristic write for Lua script
    } catch (e) {
      _logger.severe('Error uploading Lua script: $e');
      await addLogMessage('Error uploading Lua script: $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (_device != null) {
      await _device!.disconnect();
      _device = null;
      _logger.info('Disconnected from Frame');
    }
  }

  void dispose() {
    disconnect();
  }
}