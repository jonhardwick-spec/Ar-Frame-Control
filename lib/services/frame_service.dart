import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:frame_ble/brilliant_bluetooth.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:frame_ble/brilliant_scanned_device.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/auto_exp_settings.dart';
import 'package:frame_msg/tx/manual_exp_settings.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ar_project/services/storage_service.dart';
import '../models/LogEntry.dart';
import '../models/log_entry.dart';
import '../utility/api_call.dart';

enum ConnectionState { connected, disconnected } // Fallback enum

class FrameService extends WidgetsBindingObserver {
  final Logger _log = Logger('FrameService');
  BrilliantDevice? _frame;
  bool _isConnected = false;
  StreamSubscription<BrilliantScannedDevice>? _scanSub;
  StreamSubscription<BrilliantDevice>? _stateSub;
  StreamSubscription<List<int>>? _rxAppData;
  StreamSubscription<String>? _rxStdOut;
  final StorageService storageService;
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 2;
  static const Duration _scanTimeout = Duration(seconds: 15);
  bool _mtuSet = false;
  BrilliantScannedDevice? _discoveredDevice;
  final List<Future<void> Function()> _commandQueue = [];
  bool _isProcessingQueue = false;
  bool _isOperationRunning = false;
  String _apiEndpoint = '';
  int? _maxStringLength;
  final connectionState = ValueNotifier<bool>(false);

  // Camera settings from FeedService
  bool isAutoExposure = true;
  int qualityIndex = 4;
  final List<String> qualityValues = ['VERY_LOW', 'LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH'];
  int resolution = 720;
  int pan = 0;
  bool upright = true;
  int meteringIndex = 1;
  final List<String> meteringValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  double exposure = 0.1;
  double exposureSpeed = 0.45;
  int shutterLimit = 16383;
  int analogGainLimit = 16;
  double whiteBalanceSpeed = 0.5;
  int rgbGainLimit = 287;
  int manualShutter = 4096;
  int manualAnalogGain = 1;
  int manualRedGain = 121;
  int manualGreenGain = 64;
  int manualBlueGain = 140;
  final Stopwatch _stopwatch = Stopwatch();
  static const int _startListeningFlag = 0x11;
  static const int _stopListeningFlag = 0x12;

  FrameService({required this.storageService}) {
    WidgetsBinding.instance.addObserver(this);
    _log.info('FrameService initialized');
    addLogMessage('FrameService initialized');
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
      _apiEndpoint = 'https://api.example.com'; // Stub
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

  Future<void> scanForFrame() async {
    if (_isConnected && _discoveredDevice != null) {
      _log.info('already connected, skipping scan');
      addLogMessage('already connected, skipping scan');
      return;
    }
    if (!await initialize()) {
      _log.severe('bluetooth initialization failed');
      throw Exception('bluetooth initialization failed');
    }

    _log.info('scanning for frame devices');
    addLogMessage('scanning for frame devices');
    final completer = Completer<void>();
    await _scanSub?.cancel();
    _scanSub = BrilliantBluetooth.scan().timeout(_scanTimeout, onTimeout: (sink) {
      if (!_isConnected) {
        _log.warning('scan timed out after ${_scanTimeout.inSeconds} seconds');
        addLogMessage('no frame devices found');
        if (!completer.isCompleted) completer.complete();
      }
    }).listen((device) async {
      _log.info('discovered device: ${device.device.remoteId}, rssi: ${device.rssi}');
      addLogMessage('discovered device: ${device.device.remoteId}, rssi: ${device.rssi}');
      _discoveredDevice = device;
      await connectToScannedFrame(device);
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
  }

  Future<void> connectToScannedFrame(BrilliantScannedDevice device) async {
    for (int attempt = 1; attempt <= _maxRetries && !_isConnected; attempt++) {
      try {
        _log.info('connecting to device: ${device.device.remoteId}, attempt $attempt/$_maxRetries');
        addLogMessage('connecting to device: ${device.device.remoteId}');
        _frame = await BrilliantBluetooth.connect(device);
        _log.info('connected to device: ${_frame!.device.remoteId}');
        addLogMessage('connected to device: ${_frame!.device.remoteId}');

        if (!_mtuSet) {
          try {
            int mtu = await _frame!.device.requestMtu(247);
            _maxStringLength = mtu - 3;
            _log.info('mtu set to $mtu, max string length: $_maxStringLength');
            addLogMessage('mtu set to $mtu, max string length: $_maxStringLength');
            _mtuSet = true;
          } catch (e) {
            _log.warning('mtu request failed: $e');
            addLogMessage('mtu request failed: $e, using default mtu 23');
            _maxStringLength = 20;
            _mtuSet = true;
          }
        }

        await _refreshDeviceStateSubs();
        await _refreshRxSubs();
        await Future.delayed(Duration(milliseconds: 500));
        await _frame!.sendBreakSignal();
        await Future.delayed(Duration(milliseconds: 500));

        final response = await _frame!.sendString(
          'print("Connected to Frame " .. frame.FIRMWARE_VERSION .. ", Mem: " .. tostring(collectgarbage("count")))',
          awaitResponse: true,
        );
        _log.info('firmware response: $response');
        addLogMessage('firmware response: $response');

        _isConnected = true;
        await _sendConnectedIndicator();
        _updateConnectionState(true);
        _log.info('connection established successfully');
        addLogMessage('connection established successfully');
        break;
      } catch (e) {
        _log.severe('connect attempt $attempt failed: $e');
        addLogMessage('connect attempt $attempt failed: $e');
        if (attempt == _maxRetries) rethrow;
        await Future.delayed(Duration(seconds: _retryDelaySeconds));
      }
    }
  }

  Future<void> reconnectFrame() async {
    if (_frame != null && _discoveredDevice != null) {
      try {
        _log.info('reconnecting to device: ${_frame!.device.remoteId}');
        addLogMessage('reconnecting to device: ${_frame!.device.remoteId}');
        await BrilliantBluetooth.reconnect(_frame!.uuid);
        _log.info('device reconnected: ${_frame!.device.remoteId}');
        addLogMessage('device reconnected: ${_frame!.device.remoteId}');

        await _refreshDeviceStateSubs();
        await _refreshRxSubs();
        await Future.delayed(Duration(milliseconds: 500));
        await _frame!.sendBreakSignal();
        await Future.delayed(Duration(milliseconds: 500));

        final response = await _frame!.sendString(
          'print("Connected to Frame " .. frame.FIRMWARE_VERSION .. ", Mem: " .. tostring(collectgarbage("count")))',
          awaitResponse: true,
        );
        _log.info('firmware response: $response');
        addLogMessage('firmware response: $response');

        _isConnected = true;
        await _sendConnectedIndicator();
        _updateConnectionState(true);
      } catch (e) {
        _log.severe('reconnection failed: $e');
        addLogMessage('reconnection failed: $e');
        _updateConnectionState(false);
      }
    } else {
      _log.warning('no device to reconnect, scanning instead');
      addLogMessage('no device to reconnect, scanning instead');
      await scanForFrame();
    }
  }

  Future<void> _refreshDeviceStateSubs() async {
    await _stateSub?.cancel();
    _stateSub = _frame!.connectionState.listen((bcs) {
      _log.info('connection state changed: ${bcs.state}');
      addLogMessage('connection state changed: ${bcs.state}');
      if (bcs.state == ConnectionState.disconnected) {
        _updateConnectionState(false);
        Future.delayed(Duration(seconds: _retryDelaySeconds), () {
          if (!_isConnected) {
            addLogMessage('attempting to reconnect...');
            reconnectFrame();
          }
        });
      }
    });
  }

  Future<void> _refreshRxSubs() async {
    await _rxAppData?.cancel();
    _rxAppData = _frame!.dataResponse.listen((data) {
      _log.fine('received data: $data');
    });

    await _rxStdOut?.cancel();
    _rxStdOut = _frame!.stringResponse.listen((data) {
      _log.fine('received string: $data');
      addLogMessage('received string: $data');
    });
  }

  Future<void> _sendConnectedIndicator() async {
    try {
      await _frame!.sendString(
        'frame.display.text("Connected to ARC",1,1) frame.display.show()',
        awaitResponse: false,
      );
      _log.info('sent connected indicator to glasses');
      addLogMessage('sent connected indicator to glasses');
    } catch (e) {
      _log.severe('failed to send connected indicator: $e');
      addLogMessage('failed to send connected indicator: $e');
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
      addLogMessage('verifying connection');
      final response = await _sendString('print("test")');
      _log.info('test response: $response');
      addLogMessage('test response: $response');
      if (response == '"test"') {
        _updateConnectionState(true);
      }
      return response == '"test"';
    } catch (e) {
      _updateConnectionState(false);
      _log.severe('connection verification failed: $e');
      addLogMessage('connection verification failed: $e');
      return false;
    }
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
      if (!_isConnected || _frame == null) {
        throw Exception('device is not connected');
      }
      final maxLength = _maxStringLength ?? 20;
      if (string.length > maxLength) {
        _log.warning('string length ${string.length} exceeds max $maxLength, chunking');
        addLogMessage('string length ${string.length} exceeds max $maxLength, chunking');
        String response = '';
        for (int i = 0; i < string.length; i += maxLength) {
          final chunk = string.substring(i, i + maxLength > string.length ? string.length : i + maxLength);
          response += await _sendString(chunk, awaitResponse: awaitResponse, log: false);
        }
        if (log) {
          _log.info('received chunked response: $response');
          addLogMessage('received chunked response: $response');
        }
        return response;
      }
      final response = await _frame!.sendString(string, awaitResponse: awaitResponse);
      if (log && awaitResponse) {
        _log.info('received string: $response');
        addLogMessage('received string: $response');
      }
      return response ?? '';
    } catch (e) {
      _log.severe('failed to send string: $e');
      addLogMessage('failed to send string: $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      _log.info('disconnecting from frame glasses');
      addLogMessage('disconnecting from frame glasses');
      if (_frame != null) {
        await _frame!.sendBreakSignal();
        await Future.delayed(Duration(milliseconds: 500));
        await _frame!.sendResetSignal();
        await Future.delayed(Duration(milliseconds: 500));
        await _frame!.disconnect();
      }
      await _stopScan();
      _stateSub?.cancel();
      _rxAppData?.cancel();
      _rxStdOut?.cancel();
      resetConnectionState();
      _log.info('disconnected from frame glasses');
      addLogMessage('disconnected from frame glasses');
    } catch (e) {
      _log.severe('error disconnecting: $e');
      addLogMessage('error disconnecting: $e');
    }
  }

  void resetConnectionState() {
    _stopScan();
    _discoveredDevice = null;
    _isConnected = false;
    _mtuSet = false;
    _frame = null;
    _commandQueue.clear();
    _rxStdOut?.cancel();
    _rxAppData?.cancel();
    _maxStringLength = null;
    _log.info('connection state reset');
    addLogMessage('connection state reset');
  }

  Future<void> _stopScan() async {
    try {
      _log.info('stopping bluetooth scan');
      addLogMessage('stopping bluetooth scan');
      await _scanSub?.cancel();
      _scanSub = null;
      _log.info('scan stopped');
      addLogMessage('scan stopped');
    } catch (e) {
      _log.severe('error stopping scan: $e');
      addLogMessage('error stopping scan: $e');
    }
  }

  Future<T> _performOperationWithRetry<T>(Future<T> Function() operation, String operationName) async {
    if (_discoveredDevice == null) {
      _log.severe('no device connected, cannot perform $operationName');
      addLogMessage('no device connected, cannot perform $operationName');
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
            await reconnectFrame();
            await Future.delayed(const Duration(seconds: 2));
          }
          _log.info('performing $operationName, attempt $attempt/$_maxRetries');
          return await operation().timeout(const Duration(seconds: 30));
        } catch (e) {
          if (e is TimeoutException) {
            _log.severe('$operationName timed out after 30 seconds (attempt $attempt/$_maxRetries)');
            addLogMessage('$operationName timed out');
            if (attempt == _maxRetries) throw Exception('$operationName failed after maximum retries');
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
        }
      }
      _isProcessingQueue = false;
      _log.info('command queue processing completed');
      addLogMessage('command queue processing completed');
    }
  }

  // Integrated FeedService methods
  Future<void> connectToGlasses({String? deviceId}) async {
    if (deviceId != null) {
      _log.warning('Specific device ID connection not implemented, scanning instead');
      addLogMessage('Specific device ID connection not implemented, scanning instead');
    }
    await scanForFrame();
  }

  Future<List<String>> listLuaScripts() async {
    return await _performOperationWithRetry(() async {
      final response = await _sendString('print(table.concat(fs.list("/")), ",")');
      return response.split(',').where((s) => s.endsWith('.lua')).toList();
    }, 'listLuaScripts');
  }

  Future<String> downloadLuaScript(String scriptName) async {
    return await _performOperationWithRetry(() async {
      final response = await _sendString('return fs.read("/$scriptName")');
      await storageService.saveLog(LogEntry(DateTime.now(), 'Downloaded script: $scriptName'));
      return response;
    }, 'downloadLuaScript');
  }

  Stream<int> getBatteryLevelStream() {
    if (_discoveredDevice == null) {
      return Stream.value(0);
    }
    return Stream.periodic(const Duration(seconds: 20), (_) async {
      try {
        final response = await _sendString('print(frame.battery_level())');
        _log.info('Battery response: $response');
        // Handle decimal strings like "96.0"
        final level = double.parse(response.trim()).toInt();
        return level;
      } catch (e) {
        _log.severe('Battery stream error: $e');
        addLogMessage('Battery stream error: $e');
        return 0;
      }
    }).asyncMap((future) => future);
  }

  Future<BrilliantDevice?> _getFrame() async {
    if (!connectionState.value) {
      _log.warning('frame not connected, attempting to reconnect');
      addLogMessage('frame not connected, attempting to reconnect');
      await reconnectFrame();
      await Future.delayed(Duration(seconds: 2));
      if (!connectionState.value) {
        _log.severe('no frame device available after reconnect');
        addLogMessage('no frame device available after reconnect');
        throw Exception('no frame device available');
      }
    }
    if (_frame == null) {
      _log.severe('no frame device available');
      addLogMessage('no frame device available');
      throw Exception('no frame device available');
    }
    return _frame;
  }

  Future<void> updateAutoExpSettings() async {
    final frame = await _getFrame();
    final autoExpSettings = TxAutoExpSettings(
      meteringIndex: meteringIndex,
      exposure: exposure,
      exposureSpeed: exposureSpeed,
      shutterLimit: shutterLimit,
      analogGainLimit: analogGainLimit,
      whiteBalanceSpeed: whiteBalanceSpeed,
      rgbGainLimit: rgbGainLimit,
    );
    await frame!.sendMessage(0x0e, autoExpSettings.pack());
    _log.info('auto exposure settings updated');
    addLogMessage('auto exposure settings updated');
  }

  Future<void> updateManualExpSettings() async {
    final frame = await _getFrame();
    final manualExpSettings = TxManualExpSettings(
      manualShutter: manualShutter,
      manualAnalogGain: manualAnalogGain,
      manualRedGain: manualRedGain,
      manualGreenGain: manualGreenGain,
      manualBlueGain: manualBlueGain,
    );
    await frame!.sendMessage(0x0f, manualExpSettings.pack());
    _log.info('manual exposure settings updated');
    addLogMessage('manual exposure settings updated');
  }

  Future<void> sendExposureSettings() async {
    if (!connectionState.value) {
      _log.warning('cannot send exposure settings: not connected');
      addLogMessage('cannot send exposure settings: not connected');
      return;
    }
    try {
      if (isAutoExposure) {
        await updateAutoExpSettings();
      } else {
        await updateManualExpSettings();
      }
    } catch (e) {
      _log.severe('error sending exposure settings: $e');
      addLogMessage('error sending exposure settings: $e');
      rethrow;
    }
  }

  Future<(Uint8List, ImageMetadata)> capturePhoto() async {
    final frame = await _getFrame();
    try {
      _log.info('Starting photo capture');
      addLogMessage('Starting photo capture');

      // Apply exposure settings
      await sendExposureSettings();

      // Prepare metadata
      ImageMetadata meta;
      var currQualIndex = qualityIndex;
      var currRes = resolution;
      var currPan = pan;

      if (isAutoExposure) {
        meta = AutoExpImageMetadata(
          quality: qualityValues[currQualIndex],
          resolution: currRes,
          pan: currPan,
          metering: meteringValues[meteringIndex],
          exposure: exposure,
          exposureSpeed: exposureSpeed,
          shutterLimit: shutterLimit,
          analogGainLimit: analogGainLimit,
          whiteBalanceSpeed: whiteBalanceSpeed,
          rgbGainLimit: rgbGainLimit,
        );
      } else {
        meta = ManualExpImageMetadata(
          quality: qualityValues[currQualIndex],
          resolution: currRes,
          pan: currPan,
          shutter: manualShutter,
          analogGain: manualAnalogGain,
          redGain: manualRedGain,
          greenGain: manualGreenGain,
          blueGain: manualBlueGain,
        );
      }

      // Send capture command
      var takePhoto = TxCaptureSettings(
        resolution: currRes,
        qualityIndex: currQualIndex,
        pan: currPan,
        raw: RxPhoto.hasJpegHeader(qualityValues[currQualIndex], currRes),
      );
      _stopwatch.reset();
      _stopwatch.start();
      await frame!.sendMessage(0x0d, takePhoto.pack());
      _log.info('Sent photo capture command (0x0d)');
      addLogMessage('Sent photo capture command');

      // Wait for photo response
      var photoStream = RxPhoto(
        quality: qualityValues[currQualIndex],
        resolution: currRes,
        isRaw: RxPhoto.hasJpegHeader(qualityValues[currQualIndex], currRes),
        upright: upright,
      ).attach(frame.dataResponse);

      final imageData = await photoStream.first.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('Photo capture timed out after 60 seconds'),
      );

      _stopwatch.stop();
      _log.info('Received image data: ${imageData.length} bytes, time elapsed: ${_stopwatch.elapsedMilliseconds}ms');
      addLogMessage('Received image data: ${imageData.length} bytes');

      // Update metadata
      if (meta is AutoExpImageMetadata) {
        meta.size = imageData.length;
        meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;
      } else if (meta is ManualExpImageMetadata) {
        meta.size = imageData.length;
        meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;
      }

      _log.info('Photo captured successfully, size: ${imageData.length} bytes, elapsed: ${_stopwatch.elapsedMilliseconds}ms');
      addLogMessage('Photo captured successfully, size: ${imageData.length} bytes');
      return (imageData, meta);
    } catch (e) {
      _log.severe('Error capturing photo: $e');
      addLogMessage('Error capturing photo: $e');
      rethrow;
    }
  }

  Stream<Uint8List> getLiveFeedStream() async* {
    final frame = await _getFrame();
    if (frame == null) {
      _log.severe('No frame device available for live feed');
      addLogMessage('No frame device available for live feed');
      throw Exception('No frame device available');
    }
    try {
      // Start continuous capture
      await frame.sendMessage(
        _startListeningFlag,
        TxCaptureSettings(
          resolution: resolution,
          qualityIndex: qualityIndex,
          pan: pan,
          raw: false,
        ).pack(),
      );
      _log.info('Sent start listening command for live feed');
      addLogMessage('Sent start listening command for live feed');

      yield* RxPhoto(
        quality: qualityValues[qualityIndex],
        resolution: resolution,
        isRaw: false,
        upright: upright,
      ).attach(frame.dataResponse).asBroadcastStream();
    } catch (e) {
      _log.severe('Error starting live feed: $e');
      addLogMessage('Error starting live feed: $e');
      rethrow;
    }
  }

  Future<void> stopLiveFeed() async {
    await _performOperationWithRetry(() async {
      final frame = await _getFrame();
      if (frame == null) {
        _log.warning('No frame device available to stop live feed');
        addLogMessage('No frame device available to stop live feed');
        return;
      }
      try {
        await frame.sendMessage(_stopListeningFlag, TxCode(value: _stopListeningFlag).pack());
        _log.info('Sent stop listening command for live feed');
        addLogMessage('Sent stop listening command for live feed');
      } catch (e) {
        _log.severe('Error stopping live feed: $e');
        addLogMessage('Error stopping live feed: $e');
      }
    }, 'stopLiveFeed');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _stateSub?.cancel();
    _rxAppData?.cancel();
    _rxStdOut?.cancel();
    disconnect();
    _log.info('FrameService disposed');
    addLogMessage('FrameService disposed');
  }

  BrilliantDevice? get frame => _frame;
}

// Metadata classes from FeedService
class TxCode {
  final int value;
  TxCode({required this.value});
  Uint8List pack() => Uint8List.fromList([value]);
}

abstract class ImageMetadata {
  final String quality;
  final int resolution;
  final int pan;
  int size = 0;
  int elapsedTimeMs = 0;

  ImageMetadata({required this.quality, required this.resolution, required this.pan});

  List<String> toMetaDataList() => [];
}

class AutoExpImageMetadata extends ImageMetadata {
  final String metering;
  final double exposure;
  final double exposureSpeed;
  final int shutterLimit;
  final int analogGainLimit;
  final double whiteBalanceSpeed;
  final int rgbGainLimit;

  AutoExpImageMetadata({
    required super.quality,
    required super.resolution,
    required super.pan,
    required this.metering,
    required this.exposure,
    required this.exposureSpeed,
    required this.shutterLimit,
    required this.analogGainLimit,
    required this.whiteBalanceSpeed,
    required this.rgbGainLimit,
  });

  @override
  List<String> toMetaDataList() {
    return [
      'Quality: $quality\nResolution: $resolution\nPan: $pan\nMetering: ${metering.substring(0, 4)}',
      'Exposure: $exposure\nExposureSpeed: $exposureSpeed\nShutterLim: $shutterLimit\nAnalogGainLim: $analogGainLimit',
      'WBSpeed: $whiteBalanceSpeed\nRgbGainLim: $rgbGainLimit\nSize: ${(size / 1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms',
    ];
  }
}

class ManualExpImageMetadata extends ImageMetadata {
  final int shutter;
  final int analogGain;
  final int redGain;
  final int greenGain;
  final int blueGain;

  ManualExpImageMetadata({
    required super.quality,
    required super.resolution,
    required super.pan,
    required this.shutter,
    required this.analogGain,
    required this.redGain,
    required this.greenGain,
    required this.blueGain,
  });

  @override
  List<String> toMetaDataList() {
    return [
      'Quality: $quality\nResolution: $resolution\nPan: $pan\nShutter: $shutter',
      'AnalogGain: $analogGain\nRedGain: $redGain\nGreenGain: $greenGain\nBlueGain: $blueGain',
      'Size: ${(size / 1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms',
    ];
  }
}