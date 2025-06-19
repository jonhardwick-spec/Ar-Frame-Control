import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feature/feed.dart';
import 'feature/picture.dart';
import 'feature/settings.dart';
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
  final GlobalKey<SettingsScreenState> _settingsScreenKey = GlobalKey();


  // Common state
  bool _isProcessing = false;
  bool _isConnecting = false; // Local state to track connection attempts

  // Settings state
  String _apiEndpoint = '';
  int _framesToQueue = 5;
  String _cameraQuality = 'Medium';
  bool _processFramesWithApi = false;

  // App Bar Titles
  static const List<String> _appBarTitles = [
    'Frame Pictures',
    'Frame Live Feed',
    'Settings'
  ];

  @override
  void initState() {
    super.initState();
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    });
    _loadSettings(); // Load settings on app start
    _connectToDevice(); // Attempt to connect on start
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _apiEndpoint = prefs.getString('api_endpoint') ?? '';
      _framesToQueue = prefs.getInt('frames_to_queue') ?? 5;
      _cameraQuality = prefs.getString('camera_quality') ?? 'Medium';
      _processFramesWithApi = prefs.getBool('process_frames_with_api') ?? false;
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
    // Delegate to the current screen, but not for the settings page
    switch(_currentIndex) {
      case 0:
        await _pictureScreenKey.currentState?.onRun();
        break;
      case 1:
        await _feedScreenKey.currentState?.onRun();
        break;
      case 2:
      // No onRun action for settings screen
        break;
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

  // Helper method to handle connection logic
  Future<void> _connectToDevice() async {
    if (_isConnecting || frame != null) return;
    setState(() {
      _isConnecting = true;
    });

    // This method is from the SimpleFrameAppState mixin
    await tryScanAndConnectAndStart(andRun: true);

    if (mounted) {
      setState(() {
        _isConnecting = false;
      });
    }
  }

  // Helper method to handle disconnection logic
  Future<void> _disconnectFromDevice() async {
    // The `frame` object comes from the mixin.
    // The device object itself should have the disconnect method.
    await frame?.disconnect();

    // The mixin should handle setting frame to null and rebuilding,
    // but we call setState to ensure the UI updates instantly.
    if (mounted) {
      setState(() {});
    }
  }

  /// Builds a single, state-aware button for connection management.
  Widget _buildConnectButton() {
    // State 1: Actively trying to connect
    if (_isConnecting) {
      return ElevatedButton.icon(
        onPressed: null, // Disable button
        icon: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        label: const Text("Connecting..."),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.amber,
          foregroundColor: Colors.white,
        ),
      );
    }
    // State 2: Connected (the `frame` object from the mixin is available)
    else if (frame != null) {
      return ElevatedButton.icon(
        onPressed: _disconnectFromDevice,
        icon: const Icon(Icons.bluetooth_disabled),
        label: const Text("Disconnect"),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.redAccent,
          foregroundColor: Colors.white,
        ),
      );
    }
    // State 3: Disconnected
    else {
      return ElevatedButton.icon(
        onPressed: _connectToDevice,
        icon: const Icon(Icons.bluetooth),
        label: const Text("Connect"),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
        ),
      );
    }
  }

  /// Builds a Floating Action Button for Play/Pause functionality on the Feed screen.
  Widget? _buildPlayPauseFab() {
    // Only show the FAB on the Feed screen (index 1)
    if (_currentIndex != 1) return null;

    final isStreaming = _feedScreenKey.currentState?.isStreaming ?? false;

    return FloatingActionButton(
      onPressed: () {
        if (isStreaming) {
          _feedScreenKey.currentState?.stopStreaming();
        } else {
          _feedScreenKey.currentState?.startStreaming();
        }
      },
      backgroundColor: isStreaming ? Colors.redAccent : Colors.teal,
      child: Icon(
        isStreaming ? Icons.pause : Icons.play_arrow,
        color: Colors.white,
      ),
    );
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
            title: Text(_appBarTitles[_currentIndex]),
            actions: [getBatteryWidget()],
          ),
          drawer: getCameraDrawer(),
          body: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              // Reload settings when navigating away from the settings page
              if (_currentIndex == 2 && index != 2) {
                _loadSettings();
              }
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
                apiEndpoint: _apiEndpoint,
              ),
              FeedScreen(
                key: _feedScreenKey,
                frame: frame,
                capture: capture,
                isProcessing: _isProcessing,
                setProcessing: _setProcessing,
                apiEndpoint: _apiEndpoint,
                framesToQueue: _framesToQueue,
                processFramesWithApi: _processFramesWithApi,
              ),
              SettingsScreen(
                key: _settingsScreenKey,
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
              BottomNavigationBarItem(
                icon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
          floatingActionButton: _buildPlayPauseFab(),
          persistentFooterButtons: [
            Center(child: _buildConnectButton())
          ],
        ),
      ),
    );
  }
}