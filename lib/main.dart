import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Import SharedPreferences

import 'feature/feed.dart';
import 'feature/picture.dart';
import 'feature/settings.dart'; // Import the new settings screen
import 'services/foreground_service.dart';

void main() {
  initializeForegroundService();
  runApp(const MainApp());
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {
  int _currentIndex = 0;
  final PageController _pageController = PageController();

  final GlobalKey<PictureScreenState> _pictureScreenKey = GlobalKey();
  final GlobalKey<FeedScreenState> _feedScreenKey = GlobalKey();

  // Common state
  bool _isProcessing = false;

  // Settings state
  String _apiEndpoint = '';
  int _framesToQueue = 5;
  String _cameraQuality = 'Medium';
  bool _processFramesWithApi = false; // New setting

  @override
  void initState() {
    super.initState();
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
    _loadSettings(); // Load settings on app start
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // New method to load settings
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _apiEndpoint = prefs.getString('api_endpoint') ?? '';
      _framesToQueue = prefs.getInt('frames_to_queue') ?? 5;
      _cameraQuality = prefs.getString('camera_quality') ?? 'Medium';
      _processFramesWithApi = prefs.getBool('process_frames_with_api') ?? false; // Load the new setting
      _log.info("Loaded settings: API Endpoint: $_apiEndpoint, Frames to Queue: $_framesToQueue, Camera Quality: $_cameraQuality, Process with API: $_processFramesWithApi");
    });
  }

  void _setProcessing(bool processing) {
    setState(() {
      _isProcessing = processing;
    });
  }

  @override
  Future<void> onRun() async {
    // Delegate to the current screen
    if (_currentIndex == 0) {
      await _pictureScreenKey.currentState?.onRun();
    } else {
      await _feedScreenKey.currentState?.onRun();
    }
  }

  @override
  Future<void> onCancel() async {
    if (_currentIndex == 0) {
      await _pictureScreenKey.currentState?.onCancel();
    } else {
      await _feedScreenKey.currentState?.onCancel();
    }
  }

  @override
  Future<void> onTap(int taps) async {
    if (_isProcessing) return; // Prevent taps while processing

    if (_currentIndex == 0) {
      _pictureScreenKey.currentState?.handleTap(taps);
    } else {
      _feedScreenKey.currentState?.handleTap(taps);
    }
  }

  @override
  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    if (_currentIndex == 0) {
      _pictureScreenKey.currentState?.process(photo);
    } else {
      _feedScreenKey.currentState?.process(photo);
    }
  }

  @override
  Widget build(BuildContext context) {
    startForegroundService();
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Frame Vision',
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: Text(_currentIndex == 0 ? 'Frame Pictures' : 'Frame Live Feed'),
            actions: [getBatteryWidget()],
          ),
          // Add a Drawer for settings
          drawer: Drawer(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                const DrawerHeader(
                  decoration: BoxDecoration(
                    color: Colors.blueGrey,
                  ),
                  child: Text(
                    'Frame App Menu',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('Settings'),
                  onTap: () async {
                    Navigator.pop(context); // Close the drawer
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const SettingsScreen()),
                    );
                    _loadSettings(); // Reload settings when returning from SettingsScreen
                  },
                ),
                // You can add more list tiles here for other functionalities
              ],
            ),
          ),
          body: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
              onRun(); // Re-trigger onRun when switching pages
            },
            children: <Widget>[
              PictureScreen(
                key: _pictureScreenKey,
                frame: frame,
                capture: capture,
                isProcessing: _isProcessing,
                setProcessing: _setProcessing,
                apiEndpoint: _apiEndpoint, // Pass API endpoint
              ),
              FeedScreen(
                key: _feedScreenKey,
                frame: frame,
                capture: capture,
                isProcessing: _isProcessing,
                setProcessing: _setProcessing,
                apiEndpoint: _apiEndpoint, // Pass API endpoint
                framesToQueue: _framesToQueue, // Pass frames to queue setting
                processFramesWithApi: _processFramesWithApi, // Pass new setting
              ),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              _pageController.animateToPage(
                index,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.camera_alt),
                label: 'Picture',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.videocam),
                label: 'Video',
              ),
            ], // Corrected line: removed the colon after ']'
          ),
          floatingActionButton: getFloatingActionButtonWidget(
            const Icon(Icons.bluetooth),
            const Icon(Icons.bluetooth_disabled),
          ),
          persistentFooterButtons: getFooterButtonsWidget(),
        ),
      ),
    );
  }
}