import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_sdk/frame_sdk.dart' as frame_sdk;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ar_project/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/LogEntry.dart';
import '../models/log_entry.dart';
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
  // static const _batteryUuid = '7a230004-5475-a6a4-654c-8431f6ad49c4'; // Commented out as unused
  bool _isOperationRunning = false;
  final List<Future<void> Function()> _commandQueue = [];
  bool _isProcessingQueue = false;
  String _apiEndpoint = '';
  int? _maxStringLength;
  final connectionState = ValueNotifier<bool>(false);
  List<BluetoothService>? _cachedServices;

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
    debugPrint('[FrameService] Log: $message');
  }

  Future<void> _loadApiEndpoint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apiEndpoint = prefs.getString('api_endpoint') ?? '';
      _log.info('loaded api endpoint: $_apiEndpoint');
      addLogMessage('loaded api endpoint: $_apiEndpoint');
    } catch (e) {
      _log.severe('error loading api endpoint: $e');
      addLogMessage('error loading api endpoint: $e');
    }
  }

  Future<bool> initialize() async {
    debugPrint('[FrameService] Initializing Bluetooth...');
    _log.info('initializing bluetooth');

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _log.warning('location services are disabled');
        addLogMessage('please enable location services to connect to frame glasses');
        await Geolocator.openLocationSettings();
        if (!await Geolocator.isLocationServiceEnabled()) {
          _log.severe('location services not enabled');
          addLogMessage('location services required for bluetooth scanning');
          return false;
        }
      }

      int attempts = 0;
      while (attempts < 2) {
        attempts++;
        _log.info('requesting permissions, attempt $attempts/2');
        var statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
          Permission.camera,
          Permission.storage,
        ].request();
        var granted = statuses.entries.map((e) => '${e.key}: ${e.value}').join(', ');
        _log.info('permission statuses: $granted');
        addLogMessage('permission statuses: $granted');
        if (statuses.values.every((s) => s.isGranted)) {
          addLogMessage('all permissions granted');
          return true;
        }
        if (statuses.values.any((s) => s.isPermanentlyDenied)) {
          _log.severe('some permissions permanently denied');
          addLogMessage('some permissions permanently denied, opening app settings');
          await openAppSettings();
          return false;
        }
        addLogMessage('please grant all permissions to connect to frame glasses');
        await Future.delayed(const Duration(seconds: 2));
      }

      _log.severe('failed to get required permissions after $attempts attempts');
      addLogMessage('failed to get required permissions');
      return false;
    } catch (e) {
      _log.severe('error during bluetooth initialization: $e');
      addLogMessage('error during bluetooth initialization: $e');
      return false;
    }
  }

  Future<void> connectToGlasses() async {
    if (_isConnected && _discoveredDevices.isNotEmpty) {
      try {
        final state = await _discoveredDevices.first.device.connectionState.first;
        _log.info('checked connection state: $state');
        if (state == BluetoothConnectionState.connected) {
          addLogMessage('already connected, skipping connection attempt');
          return;
        }
      } catch (e) {
        _log.severe('error checking connection state: $e');
        addLogMessage('error checking connection state: $e');
      }
    }
    if (!await initialize()) {
      _log.severe('bluetooth initialization failed');
      throw Exception('bluetooth initialization failed');
    }

    for (int scanAttempt = 1; scanAttempt <= 2 && !_isConnected; scanAttempt++) {
      addLogMessage('scanning for frame devices (attempt $scanAttempt/2)');
      _discoveredDevices.clear();
      await _scanDevices();

      if (_discoveredDevices.isEmpty) {
        _log.warning('no frame devices found in scan attempt $scanAttempt');
        addLogMessage('no frame devices found');
        if (scanAttempt < 2) {
          await Future.delayed(Duration(seconds: _retryDelaySeconds));
        }
        continue;
      }

      final target = _discoveredDevices.firstWhere(
            (d) => d.rssi >= -80,
        orElse: () => throw Exception('no frame device with sufficient signal strength'),
      );
      _log.info('selected device: ${target.device.remoteId}, rssi: ${target.rssi}');
      addLogMessage('selected device: ${target.device.remoteId}, rssi: ${target.rssi}');

      for (int attempt = 1; attempt <= _maxRetries && !_isConnected; attempt++) {
        try {
          _log.info('connecting to device, attempt $attempt/$_maxRetries');
          await target.device.connect(autoConnect: false, timeout: Duration(seconds: 10));
          addLogMessage('connected to device: ${target.device.remoteId}');

          bool bonded = await _ensureBonding(target.device);
          if (!bonded) {
            addLogMessage('proceeding without bonding');
          }

          await Future.delayed(Duration(milliseconds: 500));

          await _setupCharacteristics(target.device);
          addLogMessage('services and characteristics set up');

          if (!_mtuSet) {
            try {
              int mtu = await target.device.requestMtu(247);
              _maxStringLength = mtu - 3;
              _log.info('mtu set to $mtu, max string length: $_maxStringLength');
              addLogMessage('mtu set to $mtu, max string length: $_maxStringLength');
              _mtuSet = true;
            } catch (e) {
              _log.warning('mtu request failed: $e');
              addLogMessage('mtu request failed: $e, using default mtu 23');
              _maxStringLength = 20; // Default MTU 23 - 3
              _mtuSet = true;
            }
          }

          _stateSub?.cancel();
          _stateSub = target.device.connectionState.listen((s) {
            _log.info('connection state changed: $s');
            if (s == BluetoothConnectionState.disconnected) {
              addLogMessage('device disconnected');
              _updateConnectionState(false);
              Future.delayed(Duration(seconds: _retryDelaySeconds), () {
                if (!_isConnected) {
                  addLogMessage('attempting to reconnect...');
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
          _log.info('connection established successfully');
          addLogMessage('connection established successfully');
          break;
        } catch (e) {
          _log.severe('connect attempt $attempt failed: $e');
          addLogMessage('connect attempt $attempt failed: $e');
          if (attempt < _maxRetries) {
            await Future.delayed(Duration(seconds: _retryDelaySeconds));
          } else {
            rethrow;
          }
        }
      }
    }
  }

  Future<void> _scanDevices() async {
    try {
      _log.info('starting bluetooth scan');
      addLogMessage('starting bluetooth scan');
      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (var r in results) {
          if (r.advertisementData.serviceUuids.contains(Guid(_serviceUuid)) ||
              r.advertisementData.serviceUuids.contains(Guid('fe59'))) {
            if (!_discoveredDevices.any((d) => d.device.remoteId == r.device.remoteId)) {
              _discoveredDevices.add(r);
              _log.info('discovered device: ${r.device.remoteId}, rssi: ${r.rssi}');
              addLogMessage('discovered device: ${r.device.remoteId}, rssi: ${r.rssi}');
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
      _log.info('bluetooth scan completed, found ${_discoveredDevices.length} devices');
      addLogMessage('bluetooth scan completed, found ${_discoveredDevices.length} devices');
    } catch (e) {
      _log.severe('error during bluetooth scan: $e');
      addLogMessage('error during bluetooth scan: $e');
      rethrow;
    }
  }

  Future<bool> _ensureBonding(BluetoothDevice device) async {
    try {
      _log.info('checking bond state for device: ${device.remoteId}');
      final bondState = await device.bondState.first;
      if (bondState == BluetoothBondState.bonded) {
        _log.info('device already bonded');
        addLogMessage('device already bonded');
        return true;
      }
      _log.info('creating bond with device');
      var completer = Completer<bool>();
      var sub = device.bondState.listen((state) {
        _log.info('bond state changed: $state');
        if (state == BluetoothBondState.bonded) {
          completer.complete(true);
        } else if (state == BluetoothBondState.none) {
          completer.complete(false);
        }
      });
      await device.createBond();
      bool result = await completer.future.timeout(Duration(seconds: 20), onTimeout: () {
        _log.warning('bonding timed out');
        addLogMessage('bonding timed out');
        return false;
      });
      await sub.cancel();
      addLogMessage('bonding result: $result');
      return result;
    } catch (e) {
      _log.severe('error during bonding: $e');
      addLogMessage('error during bonding: $e');
      return false;
    }
  }

  Future<void> _setupCharacteristics(BluetoothDevice device) async {
    try {
      debugPrint('[FrameService] Discovering services...');
      _log.info('discovering services for device: ${device.remoteId}');
      addLogMessage('discovering services');
      final services = _cachedServices ?? await device.discoverServices();
      _cachedServices = services;
      for (var service in services) {
        _log.info('service found: ${service.uuid}');
        debugPrint('[FrameService] Service found: ${service.uuid}');
        if (service.uuid.toString() == _serviceUuid) {
          for (var char in service.characteristics) {
            _log.info('characteristic found: ${char.uuid}');
            debugPrint('[FrameService] Characteristic found: ${char.uuid}');
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
                _log.info('enabled notifications for rx characteristic');
                addLogMessage('enabled notifications for rx characteristic');
              }
            }
          }
        }
      }
      if (_txCharacteristic == null || _rxCharacteristic == null) {
        _log.severe('failed to find required characteristics');
        addLogMessage('failed to find required characteristics');
        throw Exception('failed to find required characteristics');
      }
    } catch (e) {
      _log.severe('error setting up characteristics: $e');
      addLogMessage('error setting up characteristics: $e');
      debugPrint('[FrameService] Error setting up characteristics: $e');
      rethrow;
    }
  }

  Future<void> _sendConnectedIndicator() async {
    try {
      final command = 'frame.display.text("Connected to AR Control", 10, 10)';
      _log.info('sending connected indicator command');
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
      addLogMessage('connection invalid: not connected or no frame instance');
      return false;
    }
    try {
      _log.info('verifying connection');
      final state = await _discoveredDevices.first.device.connectionState.first;
      _log.info('bluetooth connection state: $state');
      addLogMessage('bluetooth connection state: $state');
      if (state != BluetoothConnectionState.connected) {
        _updateConnectionState(false);
        addLogMessage('connection verification failed: not connected');
        return false;
      }
      final response = await _sendString('return "test"');
      _log.info('test response: $response');
      addLogMessage('test response: $response');
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
      _log.warning('cannot stream battery level: not connected');
      addLogMessage('cannot stream battery level: not connected');
      return Stream.value(0);
    }
    return Stream.periodic(Duration(seconds: 5), (_) => checkBattery())
        .asyncMap((future) => future)
        .where((level) => level != null)
        .cast<int>();
  }

  Future<int?> checkBattery() async {
    return await _performOperationWithRetry(() async {
      if (!_isConnected || _frame == null) {
        _updateConnectionState(false);
        _log.warning('cannot check battery: not connected to frame glasses');
        addLogMessage('cannot check battery: not connected');
        debugPrint('[FrameService] Cannot check battery: not connected');
        return null;
      }
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
    return await _performOperationWithRetry(() async {
      _log.info('capturing photo, connection state: $_isConnected');
      addLogMessage('capturing photo');
      debugPrint('[FrameService] Capturing photo, connection state: $_isConnected');

      final completer = Completer<List<int>>();
      await _enqueueCommand(() async {
        try {
          final response = await _sendString('return frame.camera.capture()');
          if (response.isEmpty) {
            _log.severe('failed to capture photo: no data returned');
            throw Exception('failed to capture photo: no data returned');
          }
          final decodedData = base64Decode(response);
          _log.info('photo captured successfully, size: ${decodedData.length} bytes');
          addLogMessage('photo captured successfully, size: ${decodedData.length} bytes');
          debugPrint('[FrameService] Photo captured successfully, size: ${decodedData.length} bytes');
          completer.complete(decodedData);
        } catch (e) {
          _log.severe('error capturing photo: $e');
          addLogMessage('error capturing photo: $e');
          completer.completeError(e);
        }
      });

      return completer.future;
    }, 'capturing photo');
  }

  Future<Map<String, dynamic>> processPhoto(List<int> photoData) async {
    final apiService = ApiService(endpointUrl: _apiEndpoint);
    try {
      _log.info('processing photo');
      addLogMessage('processing photo');
      final response = await apiService.processImage(imageBytes: photoData);
      final jsonResponse = jsonDecode(response);
      _log.info('photo processed successfully: $jsonResponse');
      addLogMessage('photo processed successfully');
      return jsonResponse;
    } catch (e) {
      _log.severe('error processing photo: $e');
      addLogMessage('error processing photo: $e');
      return {'error': 'error processing photo: $e'};
    }
  }

  Future<List<String>> listLuaScripts() async {
    return await _performOperationWithRetry(() async {
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
          _log.severe('error listing lua scripts: $e');
          addLogMessage('error listing lua scripts: $e');
          completer.completeError(e);
        }
      });

      return completer.future;
    }, 'listing lua scripts');
  }

  Future<String?> downloadLuaScript(String scriptName) async {
    return await _performOperationWithRetry(() async {
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
          _log.severe('error downloading lua script: $e');
          addLogMessage('error downloading lua script: $e');
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
            throw Exception('device is not connected or characteristics not set');
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
            throw Exception('error opening file: $resp');
          }

          int index = 0;
          int chunkSize = (_maxStringLength ?? 20) - 22;

          while (index < file.length) {
            if (index + chunkSize > file.length) {
              chunkSize = file.length - index;
            }

            while (file[index + chunkSize - 1] == '\\') {
              chunkSize -= 1;
            }

            String chunk = file.substring(index, index + chunkSize);
            _log.info('writing chunk of ${chunk.length} bytes for script $scriptName');
            resp = await _sendString(
              "f:write('$chunk');print('\x02')",
              log: false,
            );
            if (resp != "\x02") {
              throw Exception('error writing file: $resp');
            }

            index += chunkSize;
          }

          resp = await _sendString("f:close();print('\x02')", log: false);
          if (resp != "\x02") {
            throw Exception('error closing file: $resp');
          }

          _log.info('uploaded script $scriptName successfully');
          addLogMessage('uploaded script $scriptName successfully');
          debugPrint('[FrameService] Uploaded script $scriptName successfully');
          completer.complete();
        } catch (e) {
          _log.severe('error uploading lua script: $e');
          addLogMessage('error uploading lua script: $e');
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
        _log.severe('device is not connected or characteristics not set');
        throw Exception('device is not connected or characteristics not set');
      }

      final maxLength = _maxStringLength ?? 20;
      if (string.length > maxLength) {
        _log.warning('string length ${string.length} exceeds max $maxLength, chunking');
        addLogMessage('string length ${string.length} exceeds max $maxLength, chunking');
        String response = '';
        for (int i = 0; i < string.length; i += maxLength) {
          final chunk = string.substring(i, i + maxLength > string.length ? string.length : i + maxLength);
          _log.info('sending chunk: $chunk');
          response += await _sendString(chunk, awaitResponse: awaitResponse, log: false);
        }
        if (log) {
          _log.info('received chunked response: $response');
          addLogMessage('received chunked response: $response');
        }
        return response;
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
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      _log.info('disconnecting from frame glasses');
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
    _cachedServices = null;
    _log.info('connection state reset');
    addLogMessage('connection state reset');
    debugPrint('[FrameService] Connection state reset');
  }

  Future<void> _stopScan() async {
    try {
      _log.info('stopping bluetooth scan');
      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();
      _scanSub = null;
      _log.info('scan stopped');
      addLogMessage('scan stopped');
      debugPrint('[FrameService] Scan stopped');
    } catch (e) {
      _log.severe('error stopping scan: $e');
      addLogMessage('error stopping scan: $e');
      debugPrint('[FrameService] Error stopping scan: $e');
    }
  }

  Future<T> _performOperationWithRetry<T>(Future<T> Function() operation, String operationName) async {
    if (_discoveredDevices.isEmpty) {
      _log.severe('no device connected, cannot perform $operationName');
      addLogMessage('no device connected, cannot perform $operationName');
      debugPrint('[FrameService] No device connected, cannot perform $operationName');
      throw Exception('no device connected');
    }

    while (_isOperationRunning) {
      _log.fine('waiting for another operation to complete before starting $operationName');
      addLogMessage('waiting for another operation to complete: $operationName');
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
          _log.info('performing $operationName, attempt $attempt/$_maxRetries');
          return await operation().timeout(const Duration(seconds: 30));
        } catch (e) {

          if (e is TimeoutException) {
            _log.severe('$operationName timed out after 30 seconds (attempt $attempt/$_maxRetries)');
            addLogMessage('$operationName timed out');
            if (attempt == _maxRetries) {
              throw Exception('$operationName failed after maximum retries');
            }
          } else if (e.toString().contains('GATT_INVALID_PDU')) {
            _log.severe('GATT_INVALID_PDU during $operationName, proceeding with default MTU');
            addLogMessage('GATT_INVALID_PDU during $operationName, proceeding');
            if (_mtuSet) {
              return await operation();
            }
          } else {
            _log.severe('error during $operationName: $e');
            addLogMessage('error during $operationName: $e');
            rethrow;
          }
          await Future.delayed(Duration(seconds: _retryDelaySeconds));
        }
      }
      throw Exception('operation failed after maximum retries');
    } finally {
      _isOperationRunning = false;
      _log.info('operation $operationName completed');
    }
  }

  Future<void> _enqueueCommand(Future<void> Function() command) async {
    _commandQueue.add(command);
    _log.info('enqueued command, queue length: ${_commandQueue.length}');
    addLogMessage('enqueued command, queue length: ${_commandQueue.length}');
    if (!_isProcessingQueue) {
      _isProcessingQueue = true;
      while (_commandQueue.isNotEmpty) {
        final cmd = _commandQueue.removeAt(0);
        try {
          _log.info('executing command from queue');
          await cmd().timeout(const Duration(seconds: 10));
          _log.info('command executed successfully');
          addLogMessage('command executed successfully');
        } catch (e) {
          _log.severe('command queue error: $e');
          addLogMessage('command queue error: $e');
          debugPrint('[FrameService] Command queue error: $e');
        }
      }
      _isProcessingQueue = false;
      _log.info('command queue processing completed');
      addLogMessage('command queue processing completed');
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _stateSub?.cancel();
    _rxSubscription?.cancel();
    disconnect();
    _log.info('FrameService disposed');
    addLogMessage('FrameService disposed');
    debugPrint('[FrameService] FrameService disposed');
  }
}