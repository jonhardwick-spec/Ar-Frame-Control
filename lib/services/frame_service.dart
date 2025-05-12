import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_sdk/frame_sdk.dart' as frame_sdk;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ar_project/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/LogEntry.dart';
import '../utility/api_call.dart';

class FrameService extends WidgetsBindingObserver {
  final Logger _log = Logger('FrameService');
  frame_sdk.Frame? _frame;
  bool _isConnected = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  final StorageService storageService;
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 2;
  static const Duration _scanTimeout = Duration(seconds: 15);
  bool _mtuSet = false;
  List<ScanResult> _discoveredDevices = [];
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<int>>? _rxSubscription;
  final List<int> _receivedData = [];
  static const _serviceUuid = '7a230001-5475-a6a4-654c-8431f6ad49c4';
  static const _txUuid = '7a230002-5475-a6a4-654c-8431f6ad49c4';
  static const _rxUuid = '7a230003-5475-a6a4-654c-8431f6ad49c4';
  static const _batteryUuid = '7a230004-5475-a6a4-654c-8431f6ad49c4';
  bool _isOperationRunning = false;
  final List<Future<void> Function()> _commandQueue = [];
  bool _isProcessingQueue = false;
  String _apiEndpoint = '';
  int? _maxStringLength;
  final connectionState = ValueNotifier<bool>(false);

  FrameService({required this.storageService}) {
    WidgetsBinding.instance.addObserver(this);
    _log.info('FrameService initialized');
    debugPrint('[FrameService] FrameService initialized');
    _updateConnectionState(false);
    _loadApiEndpoint();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _log.info('app paused, relying on foreground service for connection');
      addLogMessage('app paused, relying on foreground service for connection');
    }
  }

  void _updateConnectionState(bool state) {
    _isConnected = state;
    connectionState.value = state;
    _log.info('connection state updated to: $state');
    storageService.saveLog(LogEntry(DateTime.now(), 'Connection state updated to: $state'));
  }

  void addLogMessage(String message) {
    storageService.saveLog(LogEntry(DateTime.now(), message));
  }

  Future<void> _loadApiEndpoint() async {
    final prefs = await SharedPreferences.getInstance();
    _apiEndpoint = prefs.getString('api_endpoint') ?? '';
    _log.info('loaded api endpoint: $_apiEndpoint');
    addLogMessage('loaded api endpoint: $_apiEndpoint');
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
        Permission.camera,
        Permission.storage,
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

          await Future.delayed(Duration(milliseconds: 500));

          await target.device.discoverServices();
          addLogMessage('Services discovered');

          await _setupCharacteristics(target.device);

          if (!_mtuSet) {
            try {
              int mtu = await target.device.requestMtu(247);
              _maxStringLength = mtu - 3;
              addLogMessage('MTU set to $mtu, max string length: $_maxStringLength');
              _mtuSet = true;
            } catch (e) {
              addLogMessage('MTU request failed: $e, using default MTU 23');
              _maxStringLength = 20; // Default MTU 23 - 3
              _mtuSet = true;
            }
          }

          _stateSub?.cancel();
          _stateSub = target.device.connectionState.listen((s) {
            if (s == BluetoothConnectionState.disconnected) {
              addLogMessage('Device disconnected');
              _updateConnectionState(false);
              Future.delayed(Duration(seconds: _retryDelaySeconds), () {
                if (!_isConnected) {
                  addLogMessage('Attempting to reconnect...');
                  connectToGlasses();
                }
              });
            }
          });

          _isConnected = true;
          _frame = frame_sdk.Frame();
          await _frame!.connect();
          await _sendConnectedIndicator();
          _updateConnectionState(true);
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
        if (r.advertisementData.serviceUuids.contains(Guid(_serviceUuid)) ||
            r.advertisementData.serviceUuids.contains(Guid('fe59'))) {
          if (!_discoveredDevices.any((d) => d.device.remoteId == r.device.remoteId)) {
            _discoveredDevices.add(r);
          }
        }
      }
    });
    await FlutterBluePlus.startScan(
      withServices: [Guid(_serviceUuid), Guid('fe59')],
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

  Future<void> _setupCharacteristics(BluetoothDevice device) async {
    try {
      debugPrint('[FrameService] Discovering services...');
      final services = await device.discoverServices();
      for (var service in services) {
        print('Service found: ${service.uuid}');
        if (service.uuid.toString() == _serviceUuid) {
          for (var char in service.characteristics) {
            print('Characteristic found: ${char.uuid}');
            if (char.uuid.toString() == _txUuid) {
              _txCharacteristic = char;
              _log.info('tx characteristic found');
              addLogMessage('tx characteristic found');
              debugPrint('[FrameService] TX characteristic found');
            } else if (char.uuid.toString() == _rxUuid) {
              _rxCharacteristic = char;
              _log.info('rx characteristic found');
              addLogMessage('rx characteristic found');
              debugPrint('[FrameService] RX characteristic found');
              if (!char.isNotifying) {
                await char.setNotifyValue(true);
              }
            }
          }
        }
      }
      if (_txCharacteristic == null || _rxCharacteristic == null) {
        throw Exception('failed to find required characteristics');
      }
    } catch (e) {
      _log.severe('error setting up characteristics: $e');
      addLogMessage('error setting up characteristics: $e');
      debugPrint('[FrameService] Error setting up characteristics: $e');
      throw e;
    }
  }

  Future<void> _sendConnectedIndicator() async {
    try {
      // Validate x_position (1-640) and y_position
      final command = 'frame.display.text("Connected to AR Control", 10, 10)';
      await _sendString(command);
      _log.info('sent connected indicator to glasses');
      addLogMessage('sent connected indicator to glasses');
      debugPrint('[FrameService] Sent connected indicator to glasses');
    } catch (e) {
      _log.severe('failed to send connected indicator: $e');
      addLogMessage('failed to send connected indicator: $e');
      debugPrint('[FrameService] Failed to send connected indicator: $e');
    }
  }

  Future<bool> verifyConnection() async {
    if (!_isConnected || _frame == null) {
      _log.info('connection invalid: _isConnected=$_isConnected, _frame=${_frame != null}');
      return false;
    }
    try {
      final state = await _discoveredDevices.first.device.connectionState.first;
      _log.info('bluetooth connection state: $state');
      if (state != BluetoothConnectionState.connected) {
        _updateConnectionState(false);
        return false;
      }
      final response = await _sendString('return "test"');
      _log.info('test response: $response');
      return response == '"test"';
    } catch (e) {
      _updateConnectionState(false);
      _log.severe('connection verification failed: $e');
      addLogMessage('connection verification failed: $e');
      debugPrint('[FrameService] Connection verification failed: $e');
      return false;
    }
  }

  Stream<int> getBatteryLevelStream() {
    if (!_isConnected || _discoveredDevices.isEmpty) {
      return Stream.value(0);
    }
    return Stream.periodic(Duration(seconds: 5), (_) => checkBattery())
        .asyncMap((future) => future)
        .where((level) => level != null)
        .cast<int>();
  }

  Future<int?> checkBattery() async {
    if (!_isConnected || _frame == null) {
      _updateConnectionState(false);
      _log.warning('cannot check battery: not connected to frame glasses');
      addLogMessage('cannot check battery: not connected');
      debugPrint('[FrameService] Cannot check battery: not connected');
      return null;
    }

    return _performOperationWithRetry(() async {
      _log.info('checking battery level');
      addLogMessage('checking battery level');
      debugPrint('[FrameService] Checking battery level');
      final response = await _sendString('return frame.battery.level()');
      if (response.isEmpty) {
        _log.warning('failed to retrieve battery level');
        addLogMessage('failed to retrieve battery level');
        debugPrint('[FrameService] Failed to retrieve battery level');
        return null;
      }
      int level = int.parse(response);
      _log.info('battery level: $level%');
      addLogMessage('battery level: $level%');
      debugPrint('[FrameService] Battery level: $level%');
      return level;
    }, 'checking battery');
  }

  Future<List<int>> capturePhoto() async {
    return _performOperationWithRetry(() async {
      _log.info('capturing photo, connection state: $_isConnected');
      addLogMessage('capturing photo');
      debugPrint('[FrameService] Capturing photo, connection state: $_isConnected');

      final completer = Completer<List<int>>();
      await _enqueueCommand(() async {
        try {
          // Use correct command for photo capture
          final response = await _sendString('return frame.camera.capture()');
          if (response.isEmpty) {
            throw Exception('failed to capture photo: no data returned');
          }
          final decodedData = base64Decode(response);
          _log.info('photo captured successfully, size: ${decodedData.length} bytes');
          addLogMessage('photo captured successfully');
          debugPrint('[FrameService] Photo captured successfully, size: ${decodedData.length} bytes');
          completer.complete(decodedData);
        } catch (e) {
          completer.completeError(e);
        }
      });

      return completer.future;
    }, 'capturing photo');
  }

  Future<Map<String, dynamic>> processPhoto(List<int> photoData) async {
    final apiService = ApiService(endpointUrl: _apiEndpoint);
    try {
      final response = await apiService.processImage(imageBytes: photoData);
      final jsonResponse = jsonDecode(response);
      _log.info('photo processed successfully: $jsonResponse');
      addLogMessage('photo processed successfully');
      return jsonResponse;
    } catch (e) {
      _log.severe('error processing photo: $e');
      addLogMessage('error processing photo: $e');
      return {'error': 'Error processing photo: $e'};
    }
  }

  Future<List<String>> listLuaScripts() async {
    return _performOperationWithRetry(() async {
      _log.info('listing lua scripts on frame glasses, connection state: $_isConnected');
      addLogMessage('listing lua scripts on frame glasses');
      debugPrint('[FrameService] Listing lua scripts on frame glasses');

      final completer = Completer<List<String>>();
      await _enqueueCommand(() async {
        try {
          if (_frame == null) {
            _log.severe('no frame instance available, cannot list lua scripts');
            addLogMessage('no frame instance available, cannot list lua scripts');
            debugPrint('[FrameService] No frame instance available, cannot list lua scripts');
            completer.complete([]);
            return;
          }
          final response = await _sendString('return frame.app.list()');
          if (response.isEmpty) {
            _log.info('no lua scripts found');
            addLogMessage('no lua scripts found');
            debugPrint('[FrameService] No lua scripts found');
            completer.complete([]);
          } else {
            List<String> scripts = response.split(',').map((s) => s.trim()).toList();
            _log.info('retrieved script list: $scripts');
            addLogMessage('retrieved script list: $scripts');
            debugPrint('[FrameService] Retrieved script list: $scripts');
            completer.complete(scripts);
          }
        } catch (e) {
          completer.completeError(e);
        }
      });

      return completer.future;
    }, 'listing lua scripts');
  }

  Future<String?> downloadLuaScript(String scriptName) async {
    return _performOperationWithRetry(() async {
      _log.info('downloading lua script: $scriptName, connection state: $_isConnected');
      addLogMessage('downloading lua script: $scriptName');
      debugPrint('[FrameService] Downloading lua script: $scriptName');

      final completer = Completer<String?>();
      await _enqueueCommand(() async {
        try {
          final response = await _sendString("return frame.storage.read('$scriptName')");
          if (response.isEmpty) {
            _log.warning('script $scriptName not found');
            addLogMessage('script $scriptName not found');
            debugPrint('[FrameService] Script $scriptName not found');
            completer.complete(null);
          } else {
            _log.info('downloaded script $scriptName successfully');
            addLogMessage('downloaded script $scriptName successfully');
            debugPrint('[FrameService] Downloaded script $scriptName successfully');
            completer.complete(response);
          }
        } catch (e) {
          completer.completeError(e);
        }
      });

      return completer.future;
    }, 'downloading lua script');
  }

  Future<void> uploadLuaScript(String scriptName, String scriptContent) async {
    await _performOperationWithRetry(() async {
      _log.info('uploading lua script: $scriptName, connection state: $_isConnected');
      addLogMessage('uploading lua script: $scriptName');
      debugPrint('[FrameService] Uploading lua script: $scriptName');

      final completer = Completer<void>();
      await _enqueueCommand(() async {
        try {
          if (!_isConnected || _txCharacteristic == null || _rxCharacteristic == null) {
            throw Exception('Device is not connected or characteristics not set');
          }

          String file = scriptContent
              .replaceAll('\\', '\\\\')
              .replaceAll("\r\n", "\\n")
              .replaceAll("\n", "\\n")
              .replaceAll("'", "\\'")
              .replaceAll('"', '\\"');

          var resp = await _sendString(
            "f=frame.file.open('$scriptName', 'w');print('\x02')",
            log: false,
          );
          if (resp != "\x02") {
            throw Exception('Error opening file: $resp');
          }

          int index = 0;
          int chunkSize = (_maxStringLength ?? 247) - 22;

          while (index < file.length) {
            if (index + chunkSize > file.length) {
              chunkSize = file.length - index;
            }

            while (file[index + chunkSize - 1] == '\\') {
              chunkSize -= 1;
            }

            String chunk = file.substring(index, index + chunkSize);

            resp = await _sendString(
              "f:write('$chunk');print('\x02')",
              log: false,
            );
            if (resp != "\x02") {
              throw Exception('Error writing file: $resp');
            }

            index += chunkSize;
          }

          resp = await _sendString("f:close();print('\x02')", log: false);
          if (resp != "\x02") {
            throw Exception('Error closing file: $resp');
          }

          _log.info('uploaded script $scriptName successfully');
          addLogMessage('uploaded script $scriptName successfully');
          debugPrint('[FrameService] Uploaded script $scriptName successfully');
          completer.complete();
        } catch (e) {
          completer.completeError(e);
        }
      });

      return completer.future;
    }, 'uploading lua script');
  }

  Future<String> _sendString(
      String string, {
        bool awaitResponse = true,
        bool log = true,
      }) async {
    try {
      if (log) {
        _log.info('sending string: $string');
        addLogMessage('sending string: $string');
      }

      if (!_isConnected || _txCharacteristic == null || _rxCharacteristic == null) {
        throw Exception('Device is not connected or characteristics not set');
      }

      if (_maxStringLength != null && string.length > _maxStringLength!) {
        throw Exception('Payload exceeds allowed length of $_maxStringLength');
      }

      await _txCharacteristic!.write(utf8.encode(string), withoutResponse: !awaitResponse);

      if (!awaitResponse) {
        return '';
      }

      final response = await _rxCharacteristic!.lastValueStream
          .timeout(const Duration(seconds: 2))
          .first;

      final decoded = utf8.decode(response);
      if (log) {
        _log.info('received string: $decoded');
        addLogMessage('received string: $decoded');
      }
      return decoded;
    } catch (e) {
      _log.severe('failed to send string: $e');
      addLogMessage('failed to send string: $e');
      throw Exception('Failed to send string: $e');
    }
  }

  Future<void> disconnect() async {
    try {
      await _frame?.disconnect();
      if (_discoveredDevices.isNotEmpty) {
        await _discoveredDevices.first.device.disconnect();
      }
      await _stopScan();
      _stateSub?.cancel();
      _rxSubscription?.cancel();
      resetConnectionState();
      _log.info('disconnected from frame glasses');
      addLogMessage('disconnected from frame glasses');
      debugPrint('[FrameService] Disconnected from frame glasses');
    } catch (e) {
      _log.severe('error disconnecting: $e');
      addLogMessage('error disconnecting: $e');
      debugPrint('[FrameService] Error disconnecting: $e');
    }
  }

  void resetConnectionState() {
    _stopScan();
    _discoveredDevices.clear();
    _isConnected = false;
    _mtuSet = false;
    _frame = null;
    _commandQueue.clear();
    _receivedData.clear();
    _rxSubscription?.cancel();
    _rxSubscription = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _maxStringLength = null;
    _log.info('connection state reset');
    addLogMessage('connection state reset');
    debugPrint('[FrameService] Connection state reset');
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();
      _scanSub = null;
      _log.info('scan stopped');
      debugPrint('[FrameService] Scan stopped');
      addLogMessage('scan stopped');
    } catch (e) {
      _log.severe('error stopping scan: $e');
      debugPrint('[FrameService] Error stopping scan: $e');
      addLogMessage('error stopping scan: $e');
    }
  }

  Future<T> _performOperationWithRetry<T>(Future<T> Function() operation, String operationName) async {
    if (_discoveredDevices.isEmpty) {
      _log.severe('no device connected, cannot perform $operationName');
      addLogMessage('no device connected, cannot perform $operationName');
      debugPrint('[FrameService] No device connected, cannot perform $operationName');
      throw Exception('No device connected');
    }

    while (_isOperationRunning) {
      _log.fine('waiting for another operation to complete before starting $operationName');
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _isOperationRunning = true;
    try {
      for (int attempt = 1; attempt <= _maxRetries; attempt++) {
        try {
          if (!await verifyConnection()) {
            _log.info('connection lost, attempting to reconnect for $operationName');
            addLogMessage('connection lost, attempting to reconnect');
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
            _log.severe('error during $operationName: $e');
            addLogMessage('error during $operationName: $e');
            throw e;
          }
        }
      }
      throw Exception('operation failed after maximum retries');
    } finally {
      _isOperationRunning = false;
    }
  }

  Future<void> _enqueueCommand(Future<void> Function() command) async {
    _commandQueue.add(command);
    if (!_isProcessingQueue) {
      _isProcessingQueue = true;
      while (_commandQueue.isNotEmpty) {
        final cmd = _commandQueue.removeAt(0);
        try {
          await cmd().timeout(const Duration(seconds: 10));
        } catch (e) {
          _log.severe('command queue error: $e');
          addLogMessage('command queue error: $e');
          debugPrint('[FrameService] Command queue error: $e');
        }
      }
      _isProcessingQueue = false;
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _stateSub?.cancel();
    _rxSubscription?.cancel();
    disconnect();
    _log.info('FrameService disposed');
    debugPrint('[FrameService] FrameService disposed');
  }
}