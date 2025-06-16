import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';

import 'feature/feed.dart';
import 'feature/picture.dart';
import 'foreground_service.dart';

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

  @override
  void initState() {
    super.initState();
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
          drawer: getCameraDrawer(),
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
              ),
              FeedScreen(
                key: _feedScreenKey,
                frame: frame,
                capture: capture,
                isProcessing: _isProcessing,
                setProcessing: _setProcessing,
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
            ],
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
