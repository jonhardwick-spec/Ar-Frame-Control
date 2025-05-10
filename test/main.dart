import 'package:ar_project/app.dart';
import 'package:flutter/material.dart';
import 'package:frame_sdk/bluetooth.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });
  final Logger logger = Logger('Main');

  try {
    // Request necessary Bluetooth permissions
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();
    if (statuses.values.every((status) => status.isGranted)) {
      logger.info('All Bluetooth permissions granted');
      await BrilliantBluetooth.requestPermission();
      logger.info('BrilliantBluetooth permission granted');
    } else {
      logger.warning('Bluetooth permissions denied: $statuses');
    }
  } catch (e) {
    logger.severe('Error requesting Bluetooth permissions: $e');
  }

  runApp(const App());
}