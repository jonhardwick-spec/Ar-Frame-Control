import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/services/frame_service.dart';

final _log = Logger("Foreground task");

class ForegroundServiceManager {
  final FrameService frameService;
  ReceivePort? _receivePort;

  ForegroundServiceManager(this.frameService) {
    _setupReceivePort();
  }

  void _setupReceivePort() {
    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message == 'reconnect') {
        frameService.connectToGlasses();
      }
    });
  }

  Future<void> startForegroundService() async {
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'ar_frame_service',
          channelName: 'AR Frame Service',
          channelDescription: 'Keeps AR glasses connected in the background',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.HIGH,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: true,
          playSound: false,
        ),
        foregroundTaskOptions: const ForegroundTaskOptions(
          interval: 5000,
          isOnceEvent: false,
          autoRunOnBoot: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      await FlutterForegroundTask.startService(
        notificationTitle: 'AR Frame Service',
        notificationText: 'Maintaining connection to AR glasses',
        callback: foregroundTaskCallback,
      );
      _log.info('Foreground service started');
    } catch (e) {
      _log.severe('Error starting foreground service: $e');
    }
  }

  static void foregroundTaskCallback() {
    FlutterForegroundTask.setTaskHandler(_ForegroundTaskHandler());
  }

  Future<void> stopForegroundService() async {
    try {
      await FlutterForegroundTask.stopService();
      _receivePort?.close();
      _log.info('Foreground service stopped');
    } catch (e) {
      _log.severe('Error stopping foreground service: $e');
    }
  }
}

class _ForegroundTaskHandler extends TaskHandler {
  @override
  void onStart(DateTime timestamp, SendPort? sendPort) {
    _log.info("Starting foreground task");
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    _log.info("Foreground repeat event triggered");
    sendPort?.send('reconnect');
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) {
    _log.info("Destroying foreground task");
  }
}