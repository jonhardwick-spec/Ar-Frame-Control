import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'features/feed/feed_screen.dart';
import 'features/module_control/module_control_screen.dart';
import 'features/console_log/console_log_screen.dart';
import 'widgets/connect_button.dart';
import 'services/frame_service.dart';
import 'services/storage_service.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final StorageService _storageService = StorageService();
  late final FrameService _frameService;
  int _currentIndex = 0;
  final Logger _logger = Logger('ARFrameApp');

  @override
  void initState() {
    super.initState();
    _logger.info('app initstate called');
    _frameService = FrameService(storageService: _storageService);
    _logger.onRecord.listen((record) {
      _frameService.addLogMessage('${record.level.name}: ${record.message}');
    });
    _logger.info('frame service initialized');
  }

  @override
  void dispose() {
    _logger.info('app dispose called');
    _frameService.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _logger.info('building app with current index: $_currentIndex');
    final List<Widget> pages = [
      FeedScreen(frameService: _frameService),
      ModuleControlScreen(frameService: _frameService),
      ConsoleLogScreen(frameService: _frameService),
    ];

    return MaterialApp(
      home: ErrorBoundary(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('AR Frame Control'),
          ),
          body: pages[_currentIndex],
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              _logger.info('navigating to index: $index');
              setState(() {
                _currentIndex = index;
              });
            },
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.videocam), label: 'Feed'),
              BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Module Control'),
              BottomNavigationBarItem(icon: Icon(Icons.terminal), label: 'Console Log'),
            ],
          ),
          floatingActionButton: ConnectButton(
            onPressed: () async {
              _logger.info('connect button pressed');
              await _frameService.connectToGlasses();
            },
            frameService: _frameService,
          ),
        ),
      ),
    );
  }
}

// error boundary to catch rendering issues
class ErrorBoundary extends StatelessWidget {
  final Widget child;

  const ErrorBoundary({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        try {
          return child;
        } catch (e, stackTrace) {
          Logger('ErrorBoundary').severe('ui error: $e', e, stackTrace);
          return const Center(child: Text('UI Error: Check logs'));
        }
      },
    );
  }
}