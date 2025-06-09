import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
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
import '../../models/LogEntry.dart';
import '../utility/frame_data_models.dart';
import '../utility/servicemanagers/frame_transmission_utils.dart';

// Inspired by NOA app implementation patterns
enum ConnectionState { connected, disconnected }

enum CaptureMethod {
  messageWith0x0d,
  messageWithStartStop,
  luaDirectCapture,
  luaChunkedCapture,
  luaSimpleCapture,
  rxPhotoDirectCapture,
  luaStreamingCapture,
  luaRobustCapture,
  luaProgressiveCapture,
  optimizedCapture,
}

class FrameService extends WidgetsBindingObserver {
  final Logger _log = Logger('FrameService');
  final StorageService storageService;

  // ================================================================
  // CORE STATE & CONFIGURATION
  // ================================================================

  // Connection state
  BrilliantDevice? _frame;
  bool _isConnected = false;
  BrilliantScannedDevice? _discoveredDevice;
  final connectionState = ValueNotifier<bool>(false);

  // Enhanced connection management
  final ConnectionHealth _connectionHealth = ConnectionHealth();
  int _negotiatedMtu = 23;
  final Map<String, Completer<String>> _pendingResponses = {};
  int _messageSequence = 0;

  // Bluetooth configuration
  static const int _maxRetries = 3;
  static const int _retryDelaySeconds = 2;
  static const Duration _scanTimeout = Duration(seconds: 15);
  bool _mtuSet = false;
  int? _maxStringLength;
  String _apiEndpoint = '';

  // Operation management
  final List<Future<void> Function()> _commandQueue = [];
  bool _isOperationRunning = false;

  // Stream subscriptions
  StreamSubscription<BrilliantScannedDevice>? _scanSub;
  StreamSubscription<BrilliantDevice>? _stateSub;
  StreamSubscription<List<int>>? _rxAppData;
  StreamSubscription<String>? _rxStdOut;

  // Camera system state
  final StreamController<Uint8List> _cameraStreamController = StreamController<Uint8List>.broadcast();
  List<int> _imageBuffer = [];
  bool _isCameraReady = false;
  Timer? _continuousCaptureTimer;
  bool _isCapturingPhoto = false;

  // Photo processing state
  bool _receivingPhoto = false;
  List<int> _photoChunks = [];
  CaptureMethod? _workingCaptureMethod;

  // Battery management (doubles as heartbeat)
  int _lastBatteryLevel = 0;
  bool _batteryCheckInProgress = false;

  // Failure tracking
  int _recentFailureCount = 0;
  DateTime? _lastFailureTime;

  // Timing
  final Stopwatch _stopwatch = Stopwatch();
  static const int _startListeningFlag = 0x11;
  static const int _stopListeningFlag = 0x12;

  // Camera settings
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

  // ================================================================
  // INITIALIZATION & CONNECTION
  // ================================================================

  FrameService({required this.storageService}) {
    WidgetsBinding.instance.addObserver(this);
    addLogMessage('FrameService initialized');
    _updateConnectionState(false);
    _loadApiEndpoint();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      addLogMessage('app paused, maintaining connection monitoring');
    }
  }

  Future<bool> initialize() async {
    debugPrint('[FrameService] Initializing Bluetooth...');

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        addLogMessage('please enable location services to connect to frame glasses');
        await Geolocator.openLocationSettings();
        if (!await Geolocator.isLocationServiceEnabled()) {
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
        addLogMessage('permission statuses: $granted');
        if (statuses.values.every((s) => s.isGranted)) {
          addLogMessage('all permissions granted');
          return true;
        }
        if (statuses.values.any((s) => s.isPermanentlyDenied)) {
          addLogMessage('some permissions permanently denied, opening app settings');
          await openAppSettings();
          return false;
        }
        addLogMessage('please grant all permissions to connect to frame glasses');
        await Future.delayed(const Duration(seconds: 2));
      }
      addLogMessage('failed to get required permissions');
      return false;
    } catch (e) {
      _log.severe('error during bluetooth initialization: $e');
      addLogMessage('error during bluetooth initialization: $e');
      return false;
    }
  }

  Future<void> _loadApiEndpoint() async {
    try {
      _apiEndpoint = 'https://api.example.com'; // Stub
      addLogMessage('loaded api endpoint: $_apiEndpoint');
    } catch (e) {
      addLogMessage('error loading api endpoint: $e');
    }
  }

  // ================================================================
  // BLUETOOTH & CONNECTION MANAGEMENT
  // ================================================================

  Future<void> scanForFrame() async {
    if (_isConnected && _discoveredDevice != null) {
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
        addLogMessage('scan timed out after ${_scanTimeout.inSeconds} seconds');
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
            _negotiatedMtu = mtu;
            _log.info('mtu set to $mtu, max string length: $_maxStringLength');
            addLogMessage('mtu set to $mtu, max string length: $_maxStringLength');
            _mtuSet = true;
          } catch (e) {
            _log.warning('mtu request failed: $e');
            addLogMessage('mtu request failed: $e, using default mtu 23');
            _maxStringLength = 20;
            _negotiatedMtu = 23;
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
        await _initializeCameraSystem();
        _updateConnectionState(true);
        addLogMessage('connection established successfully');
        break;
      } catch (e) {
        addLogMessage('connect attempt $attempt failed: $e');
        _connectionHealth.recordFailure();
        if (attempt == _maxRetries) rethrow;
        await Future.delayed(Duration(seconds: _retryDelaySeconds * attempt));
      }
    }
  }

  Future<void> _negotiateOptimalMtu() async {
    if (!_mtuSet) {
      try {
        int mtu = await _frame!.device.requestMtu(247);
        _negotiatedMtu = mtu;
        _maxStringLength = mtu - 3;
        addLogMessage('MTU negotiated: $mtu, effective payload: $_maxStringLength');
        _mtuSet = true;
      } catch (e) {
        addLogMessage('MTU negotiation failed: $e, using conservative default');
        _negotiatedMtu = 23;
        _maxStringLength = 20;
        _mtuSet = true;
      }
    }
  }

  Future<void> reconnectFrame() async {
    if (_frame != null && _discoveredDevice != null) {
      try {
        addLogMessage('reconnecting to device: ${_frame!.device.remoteId}');

        await BrilliantBluetooth.reconnect(_frame!.uuid);
        addLogMessage('device reconnected: ${_frame!.device.remoteId}');

        await _negotiateOptimalMtu();
        await _refreshDeviceStateSubs();
        await _refreshRxSubs();
        await Future.delayed(Duration(milliseconds: 500));
        await _frame!.sendBreakSignal();
        await Future.delayed(Duration(milliseconds: 500));

        final response = await _sendStringWithRetry(
          'print("Reconnected to Frame " .. frame.FIRMWARE_VERSION)',
          awaitResponse: true,
        );
        addLogMessage('firmware response after reconnection: $response');

        _isConnected = true;
        await _sendConnectedIndicator();
        await _initializeCameraSystem();
        _updateConnectionState(true);
      } catch (e) {
        addLogMessage('reconnection failed: $e');
        _updateConnectionState(false);
      }
    } else {
      addLogMessage('no device to reconnect, scanning instead');
      await scanForFrame();
    }
  }

  Future<void> _refreshDeviceStateSubs() async {
    await _stateSub?.cancel();
    _stateSub = _frame!.connectionState.listen((bcs) {
      addLogMessage('connection state changed: ${bcs.state}');
      if (bcs.state == ConnectionState.disconnected) {
        _updateConnectionState(false);
        _stopContinuousCapture();
        _isCameraReady = false;

        Future.delayed(Duration(seconds: _retryDelaySeconds), () {
          if (!_isConnected) {
            addLogMessage('attempting auto-reconnection...');
            reconnectFrame();
          }
        });
      }
    });
  }

  Future<void> _refreshRxSubs() async {
    await _rxAppData?.cancel();
    _rxAppData = _frame!.dataResponse.listen((data) {
      _log.fine('received data: ${data.length} bytes');
      _handleCameraData(data);
    });

    await _rxStdOut?.cancel();
    _rxStdOut = _frame!.stringResponse.listen((data) {
      addLogMessage('received string: $data');
      _handleStringResponse(data);
    });
  }

  void _handleStringResponse(String response) {
    for (final entry in _pendingResponses.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(response);
        break;
      }
    }
  }

  Future<bool> verifyConnection() async {
    if (!_isConnected || _frame == null) {
      addLogMessage('connection invalid: _isConnected=$_isConnected, _frame=${_frame != null}');
      return false;
    }
    try {
      addLogMessage('verifying connection');
      final response = await _sendStringWithRetry('print("test")', awaitResponse: true);
      addLogMessage('test response: $response');
      final isValid = response == '"test"';
      if (isValid) {
        _updateConnectionState(true);
        _connectionHealth.recordSuccess(Duration(milliseconds: 100));
      } else {
        _connectionHealth.recordFailure();
      }
      return isValid;
    } catch (e) {
      _updateConnectionState(false);
      _connectionHealth.recordFailure();
      _log.severe('connection verification failed: $e');
      addLogMessage('connection verification failed: $e');
      return false;
    }
  }

  void _updateConnectionState(bool state) {
    _isConnected = state;
    connectionState.value = state;
    _log.info('connection state updated to: $state (health: ${(_connectionHealth.successRate * 100).toStringAsFixed(1)}%)');
    storageService.saveLog(LogEntry(DateTime.now(), 'Connection state updated to: $state'));
  }

  // ================================================================
  // ENHANCED TRANSMISSION METHODS
  // ================================================================

  Future<TransmissionResult> sendLuaScript(String luaCode, {bool awaitResponse = false, Duration? timeout}) async {
    final startTime = DateTime.now();

    try {
      addLogMessage('Sending Lua script');

      final preprocessedCode = FrameTransmissionUtils.preprocessLuaScript(luaCode);

      TransmissionResult result;
      if (preprocessedCode.length <= (_maxStringLength ?? 20)) {
        result = await _sendSinglePacket(preprocessedCode, awaitResponse: awaitResponse, timeout: timeout);
      } else {
        result = await _sendChunkedTransmission(preprocessedCode, awaitResponse: awaitResponse, timeout: timeout);
      }

      final elapsedTime = DateTime.now().difference(startTime);
      _log.info('Lua transmission complete: ${result.success ? 'SUCCESS' : 'FAILED'} (${elapsedTime.inMilliseconds}ms)');

      if (result.success) {
        _connectionHealth.recordSuccess(elapsedTime);
      } else {
        _connectionHealth.recordFailure();
      }

      return result.copyWith(elapsedTime: elapsedTime);
    } catch (e) {
      final elapsedTime = DateTime.now().difference(startTime);
      _connectionHealth.recordFailure();
      _log.severe('Lua transmission failed: $e');
      return TransmissionResult(
        success: false,
        error: e.toString(),
        bytesTransmitted: 0,
        chunkCount: 0,
        elapsedTime: elapsedTime,
      );
    }
  }

  Future<TransmissionResult> _sendSinglePacket(String luaCode, {bool awaitResponse = false, Duration? timeout}) async {
    try {
      final response = await _sendStringWithRetry(luaCode, awaitResponse: awaitResponse, timeout: timeout);

      return TransmissionResult(
        success: true,
        bytesTransmitted: luaCode.length,
        chunkCount: 1,
        elapsedTime: Duration.zero,
        response: awaitResponse ? response : null,
      );
    } catch (e) {
      return TransmissionResult(
        success: false,
        error: e.toString(),
        bytesTransmitted: 0,
        chunkCount: 0,
        elapsedTime: Duration.zero,
      );
    }
  }

  Future<TransmissionResult> _sendChunkedTransmission(String luaCode, {bool awaitResponse = false, Duration? timeout}) async {
    final maxChunkSize = (_maxStringLength ?? 20);
    final chunks = FrameTransmissionUtils.createSimpleChunks(luaCode, maxChunkSize);
    addLogMessage('Chunked transmission: ${chunks.length} chunks, max size: $maxChunkSize');

    int totalBytesSent = 0;
    String? finalResponse;

    try {
      // Send all chunks as plain text without control bytes
      for (int i = 0; i < chunks.length; i++) {
        final isLastChunk = i == chunks.length - 1;

        // Send chunk directly without any control bytes
        final response = await _sendRawWithRetry(
            chunks[i],
            awaitResponse: isLastChunk && awaitResponse,
            timeout: isLastChunk ? timeout : null
        );

        totalBytesSent += chunks[i].length;

        if (isLastChunk && awaitResponse) {
          finalResponse = response;
        }

        // Small delay between chunks to ensure proper processing
        if (!isLastChunk) {
          await Future.delayed(Duration(milliseconds: 20));
        }

        _log.fine('Sent chunk ${i + 1}/${chunks.length}');
      }

      addLogMessage('Chunked transmission completed successfully');

      return TransmissionResult(
        success: true,
        bytesTransmitted: totalBytesSent,
        chunkCount: chunks.length,
        elapsedTime: Duration.zero,
        response: awaitResponse ? finalResponse : null,
      );

    } catch (e) {
      return TransmissionResult(
        success: false,
        error: e.toString(),
        bytesTransmitted: totalBytesSent,
        chunkCount: chunks.length,
        elapsedTime: Duration.zero,
      );
    }
  }

  Future<String> _sendStringWithRetry(String string, {bool awaitResponse = true, Duration? timeout, int maxRetries = 3}) async {
    final actualTimeout = timeout ?? Duration(seconds: 10);
    Exception? lastException;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        _log.fine('Transmission attempt $attempt/$maxRetries: ${string.length} bytes');

        if (awaitResponse) {
          final sequenceId = (_messageSequence++).toString();
          final completer = Completer<String>();
          _pendingResponses[sequenceId] = completer;

          await _sendRaw(string);

          final response = await completer.future.timeout(actualTimeout);
          _pendingResponses.remove(sequenceId);

          return response;
        } else {
          await _sendRaw(string);
          return '';
        }
      } catch (e) {
        lastException = e is Exception ? e : Exception(e.toString());
        _log.warning('Transmission attempt $attempt failed: $e');

        if (attempt < maxRetries) {
          final delay = Duration(milliseconds: 100 * math.pow(2, attempt - 1).toInt());
          await Future.delayed(delay);
        }
      }
    }

    throw lastException ?? Exception('All transmission attempts failed');
  }

  Future<String> _sendRawWithRetry(String string, {bool awaitResponse = true, Duration? timeout}) async {
    return await _sendStringWithRetry(string, awaitResponse: awaitResponse, timeout: timeout, maxRetries: 1);
  }

  Future<void> _sendRaw(String string) async {
    if (!_isConnected || _frame == null) {
      throw Exception('Device is not connected');
    }
    await _frame!.sendString(string, awaitResponse: false);
  }

  // Legacy compatibility
  Future<String> _sendString(String string, {bool awaitResponse = true, bool log = true}) async {
    if (log) {
      _log.info('Legacy sendString call, routing to enhanced transmission');
    }

    final result = await sendLuaScript(string, awaitResponse: awaitResponse);
    if (!result.success) {
      throw Exception(result.error ?? 'Transmission failed');
    }

    return result.response ?? '';
  }

  // ================================================================
  // CAMERA SYSTEM MANAGEMENT
  // ================================================================

  Future<void> _initializeCameraSystem() async {
    try {
      _log.info('initializing camera system');
      addLogMessage('initializing camera system');

      _workingCaptureMethod = null;

      try {
        final batteryResult = await sendLuaScript('print(frame.battery_level())', awaitResponse: true);
        if (batteryResult.success && batteryResult.response != null) {
          _lastBatteryLevel = double.parse(batteryResult.response!.trim()).toInt();
          addLogMessage('Initial battery level: $_lastBatteryLevel%');
        }
      } catch (e) {
        _log.warning('Failed to get initial battery level: $e');
        _lastBatteryLevel = 50;
      }

      final apiCompatible = await _checkApiCompatibility();
      if (!apiCompatible) {
        addLogMessage('Camera API compatibility check failed');
        _isCameraReady = false;
        return;
      }

      await Future.delayed(Duration(milliseconds: 500));

      final initResult = await sendLuaScript(
        'for i=1,20 do frame.camera.auto() frame.sleep(0.1) end',
        awaitResponse: false,
      );

      if (initResult.success) {
        await Future.delayed(Duration(seconds: 1));
        _isCameraReady = true;
        _log.info('camera system initialized');
        addLogMessage('camera system ready');
      } else {
        throw Exception('Camera initialization failed: ${initResult.error}');
      }
    } catch (e) {
      _log.warning('camera initialization failed: $e');
      addLogMessage('camera initialization failed: $e');
      _isCameraReady = false;
    }
  }

  Future<bool> _checkApiCompatibility() async {
    try {
      _log.info('Checking Frame API compatibility');

      final testResult = await sendLuaScript(
        'if frame.camera and frame.camera.capture and frame.camera.auto and frame.camera.image_ready and frame.camera.read then print("API_OK") else print("API_MISSING") end',
        awaitResponse: true,
        timeout: Duration(seconds: 5),
      );

      if (testResult.success && testResult.response != null && testResult.response!.contains('API_OK')) {
        addLogMessage('Camera API compatibility confirmed');
        return true;
      } else {
        addLogMessage('Camera API missing: ${testResult.response ?? testResult.error}');
        return false;
      }
    } catch (e) {
      addLogMessage('API compatibility check failed: $e');
      return false;
    }
  }

  Stream<Uint8List> get cameraStream => _cameraStreamController.stream;
  bool get isCameraReady => _isCameraReady;

  void _handleCameraData(List<int> data) {
    if (data.isEmpty) return;

    if (data[0] == 0x07) {
      _receivingPhoto = true;
      _photoChunks.addAll(data.sublist(1));
      _log.fine('Received photo chunk: ${data.length - 1} bytes');
    } else if (data[0] == 0x08) {
      _photoChunks.addAll(data.sublist(1));
      _log.info('Received final photo chunk, total: ${_photoChunks.length} bytes');

      if (_photoChunks.isNotEmpty) {
        final completePhoto = Uint8List.fromList(_photoChunks);
        _cameraStreamController.add(completePhoto);
        _log.info('Photo complete: ${completePhoto.length} bytes');
        addLogMessage('Photo received: ${completePhoto.length} bytes');
      }

      _photoChunks.clear();
      _receivingPhoto = false;
    } else if (data.length > 100 && data[0] == 0xFF && data[1] == 0xD8) {
      _log.info('Received direct JPEG data: ${data.length} bytes');
      _cameraStreamController.add(Uint8List.fromList(data));
    } else if (_isCapturingPhoto && data[0] != 0x0a && data[0] != 0x0b) {
      if (!_receivingPhoto && data.length > 2 && data[0] == 0xFF && data[1] == 0xD8) {
        _receivingPhoto = true;
        _photoChunks = List.from(data);
        _log.info('Started receiving Lua photo data');
      } else if (_receivingPhoto) {
        _photoChunks.addAll(data);

        if (_photoChunks.length > 2) {
          for (int i = _photoChunks.length - 2; i >= math.max(0, _photoChunks.length - 100); i--) {
            if (_photoChunks[i] == 0xFF && _photoChunks[i + 1] == 0xD9) {
              final completePhoto = Uint8List.fromList(_photoChunks.sublist(0, i + 2));
              _cameraStreamController.add(completePhoto);
              _log.info('Lua photo complete: ${completePhoto.length} bytes');
              _photoChunks.clear();
              _receivingPhoto = false;
              break;
            }
          }
        }
      }
    }
  }

  void _trackFailure() {
    final now = DateTime.now();
    if (_lastFailureTime != null && now.difference(_lastFailureTime!).inMinutes < 5) {
      _recentFailureCount++;
    } else {
      _recentFailureCount = 1;
    }
    _lastFailureTime = now;
  }

  void _trackSuccess() {
    _recentFailureCount = 0;
    _lastFailureTime = null;
  }

  Map<String, dynamic> _getBatteryOptimizedConfig() {
    Map<String, dynamic> config = {
      'resolution': resolution,
      'quality': qualityIndex * 20 + 10,
      'pan': pan,
    };

    if (_recentFailureCount > 2) {
      config['resolution'] = config['resolution'] > 640 ? 640 : config['resolution'];
      config['quality'] = config['quality'] > 50 ? 50 : config['quality'];
      _log.info('Using degraded settings due to recent failures: $_recentFailureCount');
    }

    if (_lastBatteryLevel < 40) {
      config['resolution'] = config['resolution'] > 480 ? 480 : config['resolution'];
      config['quality'] = config['quality'] > 40 ? 40 : config['quality'];
      _log.info('Using low-power settings for battery level: $_lastBatteryLevel%');
    }

    return config;
  }

  // ================================================================
  // PHOTO CAPTURE METHODS
  // ================================================================

  Future<(Uint8List, ImageMetadata)> capturePhoto() async {
    if (_isCapturingPhoto) {
      _log.warning('Photo capture already in progress');
      throw Exception('Photo capture already in progress');
    }

    try {
      _log.info('Starting photo capture');
      addLogMessage('Starting photo capture');

      await sendExposureSettings();

      ImageMetadata meta;
      var currQualityIndex = qualityIndex;
      var currRes = resolution;
      var currPan = pan;

      if (isAutoExposure) {
        meta = AutoExpImageMetadata(
          quality: qualityValues[currQualityIndex],
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
          quality: qualityValues[currQualityIndex],
          resolution: currRes,
          pan: currPan,
          shutter: manualShutter,
          analogGain: manualAnalogGain,
          redGain: manualRedGain,
          greenGain: manualGreenGain,
          blueGain: manualBlueGain,
        );
      }

      _stopwatch.reset();
      _stopwatch.start();

      final imageData = await captureSimplePhoto();

      if (imageData == null) {
        throw Exception('Failed to capture photo with any method');
      }

      _stopwatch.stop();

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

  Future<Uint8List?> captureSimplePhoto() async {
    if (!_isCameraReady || !_isConnected) {
      _log.warning('camera not ready or not connected');
      addLogMessage('camera not ready for capture');
      return null;
    }

    if (_isCapturingPhoto) {
      _log.warning('Photo capture already in progress');
      return null;
    }

    _isCapturingPhoto = true;
    _receivingPhoto = false;

    try {
      _log.info('Starting multi-method photo capture');
      addLogMessage('Starting multi-method photo capture');

      // Try optimized method first
      try {
        final result = await _trySpecificCaptureMethod(CaptureMethod.optimizedCapture);
        if (result != null) {
          _log.info('Success with optimized method');
          addLogMessage('Photo captured successfully using optimized method');
          _workingCaptureMethod = CaptureMethod.optimizedCapture;
          _trackSuccess();
          return result;
        }
      } catch (e) {
        _log.warning('Optimized method failed: $e');
        _trackFailure();
      }

      // Try robust methods
      final robustMethods = [
        CaptureMethod.luaRobustCapture,
        CaptureMethod.luaProgressiveCapture,
      ];

      for (final method in robustMethods) {
        if (!_isCapturingPhoto) {
          _log.warning('Capture cancelled');
          return null;
        }

        _log.info('Attempting robust capture method: $method');
        addLogMessage('Trying $method');

        try {
          final result = await _trySpecificCaptureMethod(method);
          if (result != null) {
            _log.info('Success with robust method: $method');
            addLogMessage('Photo captured successfully using $method');
            _workingCaptureMethod = method;
            _trackSuccess();
            return result;
          }
        } catch (e) {
          _log.warning('Robust method $method failed: $e');
          _trackFailure();
          continue;
        }
      }

      // Try working method if available
      if (_workingCaptureMethod != null) {
        _log.info('Trying previously successful method: $_workingCaptureMethod');
        try {
          final result = await _trySpecificCaptureMethod(_workingCaptureMethod!);
          if (result != null) {
            _log.info('Previous method still works: $_workingCaptureMethod');
            return result;
          }
        } catch (e) {
          _log.warning('Previous method failed: $e');
          _workingCaptureMethod = null;
        }
      }

      // Try remaining methods
      final methods = CaptureMethod.values.where((m) =>
      m != CaptureMethod.optimizedCapture &&
          !robustMethods.contains(m)
      ).toList();

      for (final method in methods) {
        if (!_isCapturingPhoto) {
          _log.warning('Capture cancelled');
          return null;
        }

        _log.info('Attempting capture method: $method');
        addLogMessage('Trying $method');

        try {
          final result = await _trySpecificCaptureMethod(method);
          if (result != null) {
            _log.info('Success with method: $method');
            addLogMessage('Photo captured successfully using $method');
            _workingCaptureMethod = method;
            _trackSuccess();
            return result;
          }
        } catch (e) {
          _log.warning('Method $method failed: $e');
          _trackFailure();
          continue;
        }
      }

      _log.severe('All capture methods failed');
      addLogMessage('All capture methods failed');
      return null;

    } finally {
      _isCapturingPhoto = false;
      _receivingPhoto = false;
      _log.info('Photo capture complete, clearing flags');
    }
  }

  Future<Uint8List?> _trySpecificCaptureMethod(CaptureMethod method) async {
    final photoCompleter = Completer<Uint8List>();
    StreamSubscription<Uint8List>? photoSubscription;

    if (method == CaptureMethod.rxPhotoDirectCapture) {
      try {
        await _captureUsingRxPhoto(photoCompleter);
        final imageData = await photoCompleter.future.timeout(
          Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException('Capture method $method timed out');
          },
        );
        return imageData;
      } catch (e) {
        rethrow;
      }
    }

    photoSubscription = _cameraStreamController.stream.listen((imageData) {
      if (!photoCompleter.isCompleted) {
        photoCompleter.complete(imageData);
        photoSubscription?.cancel();
      }
    });

    try {
      switch (method) {
        case CaptureMethod.messageWith0x0d:
          await _captureUsingMessage0x0d();
          break;
        case CaptureMethod.messageWithStartStop:
          await _captureUsingStartStop();
          break;
        case CaptureMethod.luaDirectCapture:
          await _captureUsingLuaDirect();
          break;
        case CaptureMethod.luaChunkedCapture:
          await _captureUsingLuaChunked();
          break;
        case CaptureMethod.luaSimpleCapture:
          await _captureUsingLuaSimple();
          break;
        case CaptureMethod.luaStreamingCapture:
          await _captureUsingLuaStreaming();
          break;
        case CaptureMethod.luaRobustCapture:
          await _captureUsingLuaRobust();
          break;
        case CaptureMethod.luaProgressiveCapture:
          await _captureUsingLuaProgressive();
          break;
        case CaptureMethod.optimizedCapture:
          await _captureUsingOptimized();
          break;
        case CaptureMethod.rxPhotoDirectCapture:
          break;
      }

      final imageData = await photoCompleter.future.timeout(
        Duration(seconds: 15),
        onTimeout: () {
          photoSubscription?.cancel();
          throw TimeoutException('Capture method $method timed out');
        },
      );

      return imageData;

    } catch (e) {
      photoSubscription?.cancel();
      rethrow;
    }
  }

  // Optimized capture method
  Future<void> _captureUsingOptimized() async {
    _receivingPhoto = true;
    _photoChunks.clear();

    try {
      _log.info('Starting optimized capture');

      final config = _getBatteryOptimizedConfig();

      final captureScript = '''
        -- Optimized capture script
        local config = {
          resolution = ${config['resolution']},
          quality = ${config['quality']},
          pan = ${config['pan']}
        }
        
        if not frame.camera then
          frame.display.text("Camera unavailable", 10, 10)
          frame.display.show()
          return false
        end
        
        for i = 1, 15 do
          frame.camera.auto()
          frame.sleep(0.08)
        end
        
        frame.camera.capture(config)
        
        local timeout = 25
        local count = 0
        while not frame.camera.image_ready() and count < timeout do
          frame.sleep(0.1)
          count = count + 1
        end
        
        if count >= timeout then
          frame.display.text("Capture timeout", 10, 10)
          frame.display.show()
          return false
        end
        
        local mtu = frame.bluetooth.max_length()
        local chunk_size = math.min(mtu, 200)
        local bytes_sent = 0
        
        while true do
          local data = frame.camera.read(chunk_size)
          if not data or #data == 0 then break end
          
          frame.bluetooth.send(data)
          bytes_sent = bytes_sent + #data
          
          if bytes_sent > 150000 then break end
          frame.sleep(chunk_size > 100 and 0.03 or 0.02)
        end
        
        frame.display.text("Sent: " .. bytes_sent .. "b", 10, 10)
        frame.display.show()
        return true
      ''';

      final result = await sendLuaScript(captureScript, awaitResponse: false, timeout: Duration(seconds: 20));

      if (!result.success) {
        throw Exception('Optimized capture script failed: ${result.error}');
      }

      _log.info('Optimized capture script transmitted successfully');

    } catch (e) {
      _log.warning('Optimized capture setup failed: $e');
      rethrow;
    }
  }

  // Existing capture methods (simplified for brevity)
  Future<void> _captureUsingMessage0x0d() async {
    _photoChunks.clear();
    var takePhoto = TxCaptureSettings(
      resolution: resolution,
      qualityIndex: qualityIndex,
      pan: pan,
      raw: false,
    );
    await _frame!.sendMessage(0x0d, takePhoto.pack());
    _log.info('Sent 0x0d capture command');
  }

  Future<void> _captureUsingStartStop() async {
    _photoChunks.clear();
    await _frame!.sendMessage(
      _startListeningFlag,
      TxCaptureSettings(
        resolution: resolution,
        qualityIndex: qualityIndex,
        pan: pan,
        raw: false,
      ).pack(),
    );
    await Future.delayed(Duration(milliseconds: 500));
    await _frame!.sendMessage(_stopListeningFlag, TxCode(value: _stopListeningFlag).pack());
    _log.info('Sent start/stop listening commands');
  }

  Future<void> _captureUsingLuaDirect() async {
    const luaScript = 'for i=1,5 do frame.camera.auto()frame.sleep(0.1)end frame.camera.capture()while not frame.camera.image_ready()do frame.sleep(0.1)end local m=frame.bluetooth.max_length()local d=frame.camera.read(m)if d then frame.bluetooth.send(d)end';
    _receivingPhoto = true;
    await sendLuaScript(luaScript, awaitResponse: false);
    _log.info('Sent direct Lua capture script');
  }

  Future<void> _captureUsingLuaChunked() async {
    _receivingPhoto = true;
    await sendLuaScript('for i=1,10 do frame.camera.auto() frame.sleep(0.1) end', awaitResponse: false);
    await Future.delayed(Duration(milliseconds: 500));
    await sendLuaScript('frame.camera.capture()', awaitResponse: false);
    await Future.delayed(Duration(milliseconds: 500));
    await sendLuaScript('while not frame.camera.image_ready() do frame.sleep(0.1) end', awaitResponse: false);
    await Future.delayed(Duration(milliseconds: 500));
    await sendLuaScript('frame.camera.save_quality(50)', awaitResponse: false);
    await Future.delayed(Duration(milliseconds: 200));
    await sendLuaScript('local m=frame.bluetooth.max_length() while true do local d=frame.camera.read(m) if not d then break end frame.bluetooth.send(d) end', awaitResponse: false);
    _log.info('Sent chunked Lua capture commands');
  }

  Future<void> _captureUsingLuaSimple() async {
    _receivingPhoto = true;
    await sendLuaScript('frame.camera.auto()frame.sleep(0.5)frame.camera.capture()frame.sleep(1)frame.bluetooth.send(frame.camera.read(1000))', awaitResponse: false);
    _log.info('Sent simple Lua capture command');
  }

  Future<void> _captureUsingLuaStreaming() async {
    _receivingPhoto = true;
    _photoChunks.clear();

    try {
      _log.info('Starting streaming Lua capture');
      await sendLuaScript('frame.camera.auto() frame.sleep(0.3)', awaitResponse: false);
      await Future.delayed(Duration(milliseconds: 350));
      await sendLuaScript('frame.camera.capture()', awaitResponse: false);
      await Future.delayed(Duration(milliseconds: 300));
      await sendLuaScript('while not frame.camera.image_ready() do frame.sleep(0.05) end', awaitResponse: false);
      await Future.delayed(Duration(milliseconds: 200));
      await sendLuaScript('frame.camera.save_quality(60)', awaitResponse: false);
      await Future.delayed(Duration(milliseconds: 100));

      const streamingScript = '''
        local chunk_size = 200
        local total_sent = 0
        while true do
          local data = frame.camera.read(chunk_size)
          if not data or #data == 0 then break end
          frame.bluetooth.send(data)
          total_sent = total_sent + #data
          if total_sent > 50000 then break end
          frame.sleep(0.02)
        end
      ''';

      await sendLuaScript(streamingScript, awaitResponse: false);
      _log.info('Sent streaming Lua capture script');

    } catch (e) {
      _log.warning('Streaming capture setup failed: $e');
      rethrow;
    }
  }

  Future<void> _captureUsingLuaRobust() async {
    _receivingPhoto = true;
    _photoChunks.clear();

    try {
      _log.info('Starting robust Lua capture');
      await Future.delayed(Duration(milliseconds: 500));

      await sendLuaScript('''
        for i = 1, 20 do 
          if frame.camera and frame.camera.auto then
            frame.camera.auto()
          else
            frame.display.text("Camera API error", 10, 10)
            frame.display.show()
            return false
          end
          frame.sleep(0.1)
        end
      ''', awaitResponse: false);

      await Future.delayed(Duration(milliseconds: 500));
      final config = _getBatteryOptimizedConfig();

      await sendLuaScript('''
        if frame.camera and frame.camera.capture then
          local camera_config = {
            resolution = ${config['resolution']},
            quality = ${config['quality']},
            pan = ${config['pan']}
          }
          frame.camera.capture(camera_config)
        else
          return false
        end
      ''', awaitResponse: false);

      await Future.delayed(Duration(milliseconds: 300));

      await sendLuaScript('''
        local timeout = 30
        local count = 0
        while not frame.camera.image_ready() and count < timeout do
          frame.sleep(0.1)
          count = count + 1
        end
        
        if count >= timeout then
          frame.display.text("Image timeout", 10, 10)
          frame.display.show()
          return false
        end
      ''', awaitResponse: false);

      await Future.delayed(Duration(milliseconds: 200));

      await sendLuaScript('''
        local mtu = frame.bluetooth.max_length()
        local bytes_sent = 0
        
        while true do
          local data = frame.camera.read(mtu)
          if data == nil then break end
          
          frame.bluetooth.send(data)
          bytes_sent = bytes_sent + string.len(data)
          
          if bytes_sent > 100000 then break end
        end
        
        frame.display.text("Sent: " .. bytes_sent .. " bytes", 10, 10)
        frame.display.show()
      ''', awaitResponse: false);

      _log.info('Sent robust Lua capture script');

    } catch (e) {
      _log.warning('Robust capture setup failed: $e');
      rethrow;
    }
  }

  Future<void> _captureUsingLuaProgressive() async {
    _receivingPhoto = true;
    _photoChunks.clear();

    try {
      _log.info('Starting progressive quality capture');
      final config = _getBatteryOptimizedConfig();
      await Future.delayed(Duration(milliseconds: 500));
      await sendLuaScript('for i=1,10 do frame.camera.auto() frame.sleep(0.1) end', awaitResponse: false);
      await Future.delayed(Duration(milliseconds: 300));

      await sendLuaScript('''
        local qualities = {${config['quality']}, 40, 25}
        local resolutions = {${config['resolution']}, 480, 320}
        
        for attempt = 1, 3 do
          local camera_config = {
            resolution = resolutions[attempt],
            quality = qualities[attempt],
            pan = ${config['pan']}
          }
          
          frame.display.text("Attempt " .. attempt, 10, 10)
          frame.display.show()
          
          frame.camera.capture(camera_config)
          
          local timeout = 20
          local count = 0
          while not frame.camera.image_ready() and count < timeout do
            frame.sleep(0.1)
            count = count + 1
          end
          
          if count < timeout then
            frame.display.text("Success quality " .. qualities[attempt], 10, 10)
            frame.display.show()
            
            local mtu = frame.bluetooth.max_length()
            while true do
              local data = frame.camera.read(mtu)
              if data == nil then break end
              frame.bluetooth.send(data)
            end
            
            return true
          else
            frame.display.text("Timeout, trying lower quality", 10, 10)
            frame.display.show()
          end
        end
        
        return false
      ''', awaitResponse: false);

      _log.info('Sent progressive quality capture script');

    } catch (e) {
      _log.warning('Progressive capture setup failed: $e');
      rethrow;
    }
  }

  Future<void> _captureUsingRxPhoto(Completer<Uint8List> completer) async {
    _log.info('Using RxPhoto direct capture');

    final rxPhoto = RxPhoto(
      quality: qualityValues[qualityIndex],
      resolution: resolution,
      isRaw: false,
      upright: upright,
    );

    final photoStream = rxPhoto.attach(_frame!.dataResponse);

    final subscription = photoStream.listen((imageData) {
      if (!completer.isCompleted) {
        completer.complete(imageData);
      }
    });

    var takePhoto = TxCaptureSettings(
      resolution: resolution,
      qualityIndex: qualityIndex,
      pan: pan,
      raw: false,
    );
    await _frame!.sendMessage(0x0d, takePhoto.pack());

    Future.delayed(Duration(seconds: 15), () {
      subscription.cancel();
    });
  }

  // ================================================================
  // LIVE FEED & CONTINUOUS CAPTURE
  // ================================================================

  Stream<Uint8List> getLiveFeedStream() async* {
    final frame = await _getFrame();
    if (frame == null) {
      _log.severe('No frame device available for live feed');
      addLogMessage('No frame device available for live feed');
      throw Exception('No frame device available');
    }

    try {
      _log.info('Starting live feed');
      addLogMessage('Starting live feed');

      if (_workingCaptureMethod != null) {
        _log.info('Using known working method for live feed: $_workingCaptureMethod');

        while (true) {
          final photo = await captureSimplePhoto();
          if (photo != null) {
            yield photo;
          }
          await Future.delayed(Duration(milliseconds: 100));
        }
      } else {
        _log.info('No known working method, using RxPhoto approach');

        final rxPhoto = RxPhoto(
          quality: qualityValues[qualityIndex],
          resolution: resolution,
          isRaw: false,
          upright: upright,
        );

        final photoStream = rxPhoto.attach(frame.dataResponse).asBroadcastStream();

        while (true) {
          var captureSettings = TxCaptureSettings(
            resolution: resolution,
            qualityIndex: qualityIndex,
            pan: pan,
            raw: false,
          );

          await frame.sendMessage(0x0d, captureSettings.pack());

          try {
            final photo = await photoStream.first.timeout(
              Duration(seconds: 5),
              onTimeout: () => throw TimeoutException('Live feed frame timeout'),
            );
            yield photo;
          } catch (e) {
            _log.warning('Live feed frame error: $e');
            final photo = await captureSimplePhoto();
            if (photo != null) {
              yield photo;
            }
          }

          await Future.delayed(Duration(milliseconds: 100));
        }
      }
    } catch (e) {
      _log.severe('Error in live feed: $e');
      addLogMessage('Error in live feed: $e');
      rethrow;
    }
  }

  Future<void> startContinuousCapture({int intervalMs = 2000}) async {
    if (!_isCameraReady || !_isConnected) {
      _log.warning('cannot start continuous capture: camera not ready');
      addLogMessage('cannot start continuous capture: camera not ready');
      return;
    }

    _stopContinuousCapture();

    _log.info('starting continuous capture with ${intervalMs}ms interval');
    addLogMessage('starting continuous capture');

    _continuousCaptureTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) async {
      if (!_isConnected || !_isCameraReady) {
        _stopContinuousCapture();
        return;
      }

      if (_isCapturingPhoto) {
        _log.fine('Skipping continuous capture - already capturing');
        return;
      }

      try {
        await captureSimplePhoto();
      } catch (e) {
        _log.warning('continuous capture error: $e');
      }
    });
  }

  void _stopContinuousCapture() {
    if (_continuousCaptureTimer != null) {
      _continuousCaptureTimer!.cancel();
      _continuousCaptureTimer = null;
      _log.info('stopped continuous capture');
      addLogMessage('stopped continuous capture');
    }
  }

  Future<void> stopLiveFeed() async {
    _log.info('Live feed will stop when stream is cancelled');
    addLogMessage('Live feed stopped');
  }

  // ================================================================
  // SETTINGS MANAGEMENT
  // ================================================================

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

  Future<void> _sendConnectedIndicator() async {
    try {
      final result = await sendLuaScript(
        'frame.display.text("Connected to ARC",1,1) frame.display.show()',
        awaitResponse: false,
      );
      if (result.success) {
        _log.info('sent connected indicator to glasses');
        addLogMessage('sent connected indicator to glasses');
      } else {
        throw Exception(result.error);
      }
    } catch (e) {
      _log.severe('failed to send connected indicator: $e');
      addLogMessage('failed to send connected indicator: $e');
    }
  }

  // ================================================================
  // UTILITY & HELPER METHODS
  // ================================================================

  // Battery stream doubles as heartbeat - no capture interference
  Stream<int> getBatteryLevelStream() {
    if (_discoveredDevice == null) {
      return Stream.value(0);
    }
    return Stream.periodic(const Duration(seconds: 30), (_) async {
      try {
        // Skip if photo capture in progress to avoid interference
        if (_isCapturingPhoto || _batteryCheckInProgress || _receivingPhoto) {
          _log.info('Skipping battery check - operation in progress, returning cached: $_lastBatteryLevel');
          return _lastBatteryLevel;
        }

        _batteryCheckInProgress = true;

        if (_isCapturingPhoto) {
          _batteryCheckInProgress = false;
          return _lastBatteryLevel;
        }

        final result = await sendLuaScript('print(frame.battery_level())', awaitResponse: true, timeout: Duration(seconds: 5));
        if (result.success && result.response != null) {
          _log.info('Battery response: ${result.response}');

          final level = double.parse(result.response!.trim()).toInt();
          _lastBatteryLevel = level;
          _batteryCheckInProgress = false;

          // Record as successful heartbeat
          _connectionHealth.recordSuccess(Duration(milliseconds: 100));

          return level;
        } else {
          throw Exception(result.error ?? 'No battery response');
        }
      } catch (e) {
        _log.severe('Battery stream error: $e');
        addLogMessage('Battery stream error: $e');
        _batteryCheckInProgress = false;

        // Record as failed heartbeat
        _connectionHealth.recordFailure();

        // Trigger reconnection if health is poor
        if (_connectionHealth.successRate < 0.7) {
          _log.warning('Connection health poor (${(_connectionHealth.successRate * 100).toStringAsFixed(1)}%), attempting reconnection');
          addLogMessage('Connection health poor, attempting reconnection');
          if (!connectionState.value){
            Future.microtask(() => reconnectFrame());
          }
        }

        return _lastBatteryLevel;
      }
    }).asyncMap((future) => future);
  }

  Future<BrilliantDevice?> _getFrame() async {
    if (!connectionState.value) {
      _log.warning('frame not connected, attempting reconnect');
      addLogMessage('frame not connected, attempting reconnect');
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
            _log.info('connection lost, attempting reconnect for $operationName');
            addLogMessage('connection lost, attempting reconnect');
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
          await Future.delayed(Duration(seconds: _retryDelaySeconds * attempt));
        }
      }
      throw Exception('operation failed after maximum retries');
    } finally {
      _isOperationRunning = false;
      _log.info('operation $operationName completed');
    }
  }

  void addLogMessage(String message) {
    storageService.saveLog(LogEntry(DateTime.now(), message));
    debugPrint('[FrameService] Log: $message');
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
      final result = await sendLuaScript('print(table.concat(fs.list("/")), ","))', awaitResponse: true);
      if (result.success && result.response != null) {
        return result.response!.split(',').where((s) => s.endsWith('.lua')).toList();
      } else {
        throw Exception(result.error ?? 'Failed to list Lua scripts');
      }
    }, 'listLuaScripts');
  }

  Future<String> downloadLuaScript(String scriptName) async {
    return await _performOperationWithRetry(() async {
      final result = await sendLuaScript('return fs.read("/$scriptName")', awaitResponse: true);
      if (result.success && result.response != null) {
        await storageService.saveLog(LogEntry(DateTime.now(), 'Downloaded script: $scriptName'));
        return result.response!;
      } else {
        throw Exception(result.error ?? 'Failed to download script');
      }
    }, 'downloadLuaScript');
  }

  // Getter methods for debugging
  String get workingCaptureMethod => _workingCaptureMethod?.toString() ?? 'None found yet';
  String get connectionHealthReport => 'Success Rate: ${(_connectionHealth.successRate * 100).toStringAsFixed(1)}%, Avg Latency: ${_connectionHealth.averageLatency.inMilliseconds}ms, MTU: $_negotiatedMtu';

  void resetCaptureMethod() {
    _workingCaptureMethod = null;
    _recentFailureCount = 0;
    _lastFailureTime = null;
    _log.info('Reset capture method - will try optimized methods first on next capture');
    addLogMessage('Reset capture method - optimized methods prioritized');
  }

  Future<void> disconnect() async {
    try {
      _log.info('disconnecting from frame glasses');
      addLogMessage('disconnecting from frame glasses');

      _stopContinuousCapture();

      // Clear pending responses
      for (final completer in _pendingResponses.values) {
        if (!completer.isCompleted) {
          completer.completeError('Connection closed');
        }
      }
      _pendingResponses.clear();

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
    _negotiatedMtu = 23;

    _pendingResponses.clear();
    _messageSequence = 0;

    _isCameraReady = false;
    _stopContinuousCapture();
    _imageBuffer.clear();
    _photoChunks.clear();
    _receivingPhoto = false;
    _workingCaptureMethod = null;

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

  BrilliantDevice? get frame => _frame;

  // ================================================================
  // CLEANUP & DISPOSAL
  // ================================================================

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _stateSub?.cancel();
    _rxAppData?.cancel();
    _rxStdOut?.cancel();

    _stopContinuousCapture();
    _cameraStreamController.close();

    // Clear pending responses
    for (final completer in _pendingResponses.values) {
      if (!completer.isCompleted) {
        completer.completeError('Service disposed');
      }
    }
    _pendingResponses.clear();

    disconnect();
    _log.info('FrameService disposed');
    addLogMessage('FrameService disposed');
  }
}

// ================================================================
// METADATA CLASSES (kept in main file for now)
// ================================================================

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