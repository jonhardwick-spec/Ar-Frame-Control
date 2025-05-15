import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'services/frame_service.dart';
import 'services/storage_service.dart';
import 'features/feed/feed_screen.dart';
import 'features/module_control/module_control_screen.dart';
import 'features/console_log/console_log_screen.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  int _selectedIndex = 0;
  late FrameService frameService;
  late StorageService storageService;
  final StreamController<LogRecord> _logController = StreamController<LogRecord>.broadcast();
  StreamSubscription<LogRecord>? _logSubscription;

  @override
  void initState() {
    super.initState();
    storageService = StorageService();
    frameService = FrameService(storageService: storageService);
    _setupLogging();
  }

  void _setupLogging() {
    _logSubscription = Logger.root.onRecord.listen((record) {
      _logController.add(record);
    });
    _logController.stream.listen((record) async {
      frameService.addLogMessage(record.message.toString());
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _logController.close();
    frameService.disconnect();
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Frame Control'),
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          FeedScreen(frameService: frameService),
          ModuleControlScreen(frameService: frameService, storageService: storageService),
          ConsoleLogScreen(storageService: storageService),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.photo),
            label: 'Feed',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Module Control',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list),
            label: 'Console Log',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.amber[800],
        onTap: _onItemTapped,
      ),
    );
  }
}