import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/auto_exp_settings.dart';
import 'package:frame_msg/tx/manual_exp_settings.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:ar_project/services/storage_service.dart';
import 'package:ar_project/services/frame_service.dart';
import '../models/LogEntry.dart';

class FeedService {
  final Logger _log = Logger('FeedService');
  final FrameService frameService;
  final StorageService storageService;
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

  FeedService({required this.storageService, required this.frameService}) {
    _log.info('FeedService initialized');
    addLogMessage('FeedService initialized');
  }

  void addLogMessage(String message) {
    storageService.saveLog(LogEntry(DateTime.now(), message));
    debugPrint('[FeedService] Log: $message');
  }

  Future<BrilliantDevice?> _getFrame() async {
    if (!frameService.connectionState.value) {
      _log.warning('frame not connected, attempting to reconnect');
      addLogMessage('frame not connected, attempting to reconnect');
      await frameService.reconnectFrame();
      await Future.delayed(Duration(seconds: 2));
      if (!frameService.connectionState.value) {
        _log.severe('no frame device available after reconnect');
        addLogMessage('no frame device available after reconnect');
        throw Exception('no frame device available');
      }
    }
    final frame = frameService.frame;
    if (frame == null) {
      _log.severe('no frame device available');
      addLogMessage('no frame device available');
      throw Exception('no frame device available');
    }
    return frame;
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
    if (!frameService.connectionState.value) {
      _log.warning('cannot send exposure settings: not connected');
      addLogMessage('cannot send exposure settings: not connected');
      return;
    }
    if (isAutoExposure) {
      await updateAutoExpSettings();
    } else {
      await updateManualExpSettings();
    }
  }

  Future<(Uint8List, ImageMetadata)> capturePhoto() async {
    final frame = await _getFrame();
    try {
      // Test device responsiveness
      final testResponse = await frame!.sendString('return "test"', awaitResponse: true);
      _log.info('device test response: $testResponse');
      addLogMessage('device test response: $testResponse');
      if (testResponse != '"test"') {
        addLogMessage('device not responsive');
        throw Exception('device not responsive');
      }

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
      bool requestRaw = RxPhoto.hasJpegHeader(qualityValues[currQualIndex], currRes);
      _stopwatch.reset();
      _stopwatch.start();

      // Start listening for image data
      await frame!.sendMessage(
        _startListeningFlag,
        TxCaptureSettings(
          resolution: currRes,
          qualityIndex: currQualIndex,
          pan: currPan,
          raw: requestRaw,
        ).pack(),
      );
      _log.info('sent start listening command for photo capture');

      Uint8List imageData = await RxPhoto(
        quality: qualityValues[currQualIndex],
        resolution: currRes,
        isRaw: requestRaw,
        upright: upright,
      ).attach(frame.dataResponse).first.timeout(Duration(seconds: 30), onTimeout: () {
        throw TimeoutException('photo capture timed out after 30 seconds');
      });

      // Stop listening
      await frame!.sendMessage(_stopListeningFlag, TxCode(value: _stopListeningFlag).pack());
      _log.info('sent stop listening command after photo capture');

      _stopwatch.stop();
      _log.info('size of imageData: ${imageData.length} bytes, time elapsed: ${_stopwatch.elapsedMilliseconds}ms');
      addLogMessage('received image data: ${imageData.length} bytes');

      if (meta is AutoExpImageMetadata) {
        meta.size = imageData.length;
        meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;
      } else if (meta is ManualExpImageMetadata) {
        meta.size = imageData.length;
        meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;
      }

      _log.info('photo captured successfully, size: ${imageData.length} bytes, elapsed: ${_stopwatch.elapsedMilliseconds}ms');
      addLogMessage('photo captured successfully, size: ${imageData.length} bytes');
      return (imageData, meta);
    } catch (e) {
      _log.severe('error capturing photo: $e');
      addLogMessage('error capturing photo: $e');
      rethrow;
    }
  }

  Stream<Uint8List> getLiveFeedStream() async* {
    final frame = await _getFrame();
    if (frame == null) {
      _log.severe('no frame device available for live feed');
      addLogMessage('no frame device available for live feed');
      throw Exception('no frame device available');
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
      _log.info('sent start listening command for live feed');

      yield* RxPhoto(
        quality: qualityValues[qualityIndex],
        resolution: resolution,
        isRaw: false,
        upright: upright,
      ).attach(frame.dataResponse).asBroadcastStream();

      // Note: Stream will continue until cancelled externally
    } catch (e) {
      _log.severe('error starting live feed: $e');
      addLogMessage('error starting live feed: $e');
      rethrow;
    }
  }

  Future<void> stopLiveFeed() async {
    final frame = await _getFrame();
    if (frame == null) {
      _log.warning('no frame device available to stop live feed');
      addLogMessage('no frame device available to stop live feed');
      return;
    }
    try {
      await frame.sendMessage(_stopListeningFlag, TxCode(value: _stopListeningFlag).pack());
      _log.info('sent stop listening command for live feed');
      addLogMessage('sent stop listening command for live feed');
    } catch (e) {
      _log.severe('error stopping live feed: $e');
      addLogMessage('error stopping live feed: $e');
    }
  }
}

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