import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:frame_ble/brilliant_connection_state.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feature/feed.dart';
import 'feature/picture.dart';
import 'feature/settings.dart';
import 'services/event_service.dart'; // Import the new service
import 'services/foreground_service.dart';

void main() {
  initializeForegroundService();
  runApp(const MainApp());
}

final log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {
  int currentIndex = 0;
  final PageController pageController = PageController();

  final GlobalKey<PictureScreenState> pictureScreenKey = GlobalKey();
  final GlobalKey<FeedScreenState> feedScreenKey = GlobalKey();
  final GlobalKey<SettingsScreenState> settingsScreenKey = GlobalKey();

  bool isProcessing = false;
  bool isConnecting = false;

  String apiEndpoint = '';
  int framesToQueue = 5;
  String cameraQuality = 'Medium';
  bool processFramesWithApi = false;

  bool localIsAutoExposure = true;

  Timer? heartbeatTimer;
  late StreamSubscription<AppEvent> eventSubscription; // To manage the event listener

  static const List<String> appBarTitles = [
    'Frame Pictures',
    'Frame Live Feed',
    'Settings'
  ];

  @override
  void initState() {
    super.initState();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    });
    _loadSettings();
    _loadCameraSettings();
    _startHeartbeatTimer();
    _setupEventListeners(); // Start listening for events
  }

  @override
  void dispose() {
    pageController.dispose();
    heartbeatTimer?.cancel();
    eventSubscription.cancel(); // Stop listening to events
    super.dispose();
  }

  /// Subscribes to the event stream and sets up handlers.
  void _setupEventListeners() {
    eventSubscription = EventService().on<AppEvent>().listen((event) {
      if (event is HeartbeatEvent) {
        _handleHeartbeat();
      } else if (event is ConnectionChangedEvent) {
        _handleConnectionChange(event);
      } else if (event is SettingsChangedEvent) {
        _checkAndApplySettingsChanges();
      }
    });
  }

  /// Logic to execute when a HeartbeatEvent is received.
  Future<void> _handleHeartbeat() async {
    if (frame != null && frame!.device.isConnected) {
      try {
        log.info("Sending heartbeat to frame device...");
        final result = await frame!.sendString('print("Heartbeat")', awaitResponse: true);
        if (result.toString().contains("Heartbeat")) {
          log.info("Heartbeat acknowledged by frame device.");
        } else {
          log.warning("Heartbeat not acknowledged. Response: $result");
        }
      } catch (e) {
        log.severe("Error sending heartbeat: $e");
      }
    }
  }

  /// Logic to execute when a ConnectionChangedEvent is received.
  void _handleConnectionChange(ConnectionChangedEvent event) {
    if (!mounted) return;

    // Update the UI state
    setState(() {
      isConnecting = false;
    });

    // Show a snackbar with the connection message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(event.message ?? (event.isConnected ? 'Connected!' : 'Disconnected.')),
        backgroundColor: event.isConnected ? Colors.green : Colors.grey,
        duration: const Duration(seconds: 2),
      ),
    );
  }


  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      apiEndpoint = prefs.getString('api_endpoint') ?? '';
      framesToQueue = prefs.getInt('frames_to_queue') ?? 5;
      cameraQuality = prefs.getString('camera_quality') ?? 'Medium';
      processFramesWithApi = prefs.getBool('process_frames_with_api') ?? false;
      log.info("Loaded settings: API Endpoint: $apiEndpoint, Frames to Queue: $framesToQueue, Camera Quality: $cameraQuality, Process with API: $processFramesWithApi");
    });
  }

  Future<void> _loadCameraSettings() async {
    final prefs = await SharedPreferences.getInstance();

    qualityIndex = prefs.getInt('camera_quality_index') ?? 2;
    resolution = prefs.getInt('camera_resolution') ?? 720;
    pan = prefs.getInt('camera_pan') ?? 0;
    localIsAutoExposure = prefs.getBool('camera_auto_exposure') ?? true;

    meteringIndex = prefs.getInt('camera_metering_index') ?? 1;
    exposure = prefs.getDouble('camera_exposure') ?? 0.1;
    exposureSpeed = prefs.getDouble('camera_exposure_speed') ?? 0.45;
    shutterLimit = prefs.getInt('camera_shutter_limit') ?? 16383;
    analogGainLimit = prefs.getInt('camera_analog_gain_limit') ?? 16;
    whiteBalanceSpeed = prefs.getDouble('camera_white_balance_speed') ?? 0.5;
    rgbGainLimit = prefs.getInt('camera_rgb_gain_limit') ?? 287;

    manualShutter = prefs.getInt('camera_manual_shutter') ?? 4096;
    manualAnalogGain = prefs.getInt('camera_manual_analog_gain') ?? 1;
    manualRedGain = prefs.getInt('camera_manual_red_gain') ?? 121;
    manualGreenGain = prefs.getInt('camera_manual_green_gain') ?? 64;
    manualBlueGain = prefs.getInt('camera_manual_blue_gain') ?? 140;

    if (frame != null) {
      await _applyCameraSettings();
    }

    await prefs.setBool('camera_settings_changed', false);

    log.info("Camera settings loaded: Quality=$qualityIndex, Resolution=$resolution, Pan=$pan, AutoExp=$localIsAutoExposure");
  }

  Future<void> _applyCameraSettings() async {
    if (frame == null) return;

    try {
      await sendExposureSettings();
      log.info("Applied camera settings to frame device");
    } catch (e) {
      log.severe("Error applying camera settings: $e");
    }
  }

  @override
  Future<void> sendExposureSettings() async {
    if (localIsAutoExposure) {
      await updateAutoExpSettings();
    } else {
      await updateManualExpSettings();
    }
  }

  void _setProcessing(bool processing) {
    setState(() {
      isProcessing = processing;
    });
  }

  @override
  Future<void> onRun() async {
    switch(currentIndex) {
      case 0:
        await pictureScreenKey.currentState?.onRun();
        break;
      case 1:
        await feedScreenKey.currentState?.onRun();
        break;
      case 2:
        break;
    }
  }

  @override
  Future<void> onCancel() async {
    if (currentIndex == 0) {
      await pictureScreenKey.currentState?.onCancel();
    } else {
      await feedScreenKey.currentState?.onCancel();
    }
  }

  @override
  Future<void> onTap(int taps) async {
    if (isProcessing) return;

    if (currentIndex == 0) {
      pictureScreenKey.currentState?.handleTap(taps);
    } else {
      feedScreenKey.currentState?.handleTap(taps);
    }
  }

  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    if (currentIndex == 0) {
      pictureScreenKey.currentState?.process(photo);
    } else {
      feedScreenKey.currentState?.process(photo);
    }
  }

  Future<void> _connectToDevice() async {
    if (isConnecting || frame != null) return;

    log.info("Starting connection attempt...");
    setState(() {
      isConnecting = true;
    });

    try {
      await tryScanAndConnectAndStart(andRun: true).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          log.warning("Connection attempt timed out after 10 seconds");
          throw TimeoutException('Connection timed out', const Duration(seconds: 10));
        },
      );

      if (frame != null) {
        log.info("Successfully connected to frame device");
        await _applyCameraSettings();
        // Fire a success event
        EventService().fire(ConnectionChangedEvent(isConnected: true, message: 'Successfully connected to Frame!'));
      } else {
        log.warning("Connection completed but frame is null");
        // Fire a failure event
        EventService().fire(ConnectionChangedEvent(isConnected: false, message: 'Connection failed - no device found'));
      }
    } catch (e) {
      log.severe("Connection failed: $e");
      String errorMessage = (e is TimeoutException)
          ? 'Connection timed out - check if Frame is nearby'
          : 'Connection failed: ${e.toString()}';
      // Fire a failure event with the specific error
      EventService().fire(ConnectionChangedEvent(isConnected: false, message: errorMessage));
    } finally {
      if (mounted) {
        // The event handler will now set _isConnecting to false.
        // We can remove the setState here to avoid redundancy.
      }
    }
  }

  Future<void> _disconnectFromDevice() async {
    log.info("Disconnecting from frame device...");
    disconnectFrame();
    // Fire a disconnect event
    EventService().fire(ConnectionChangedEvent(isConnected: false, message: 'Disconnected from Frame'));

    // Set frame to null in the state
    setState(() {
      frame = null;
    });
  }

  Future<void> _checkAndApplySettingsChanges() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsChanged = prefs.getBool('camera_settings_changed') ?? false;

    if (settingsChanged) {
      log.info("Settings changed, reloading and applying...");
      await _loadCameraSettings();
    }
  }

  Widget _buildConnectButton() {
    if (isConnecting) {
      return Container(
        height: 48,
        child: ElevatedButton.icon(
          onPressed: null,
          icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          label: const Text("Connecting..."),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange.shade600,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
      );
    }
    else if (frame != null) {
      return Container(
        height: 48,
        child: ElevatedButton.icon(
          onPressed: _disconnectFromDevice,
          icon: const Icon(Icons.bluetooth_disabled),
          label: const Text("Disconnect"),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade600,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
      );
    }
    else {
      return Container(
        height: 48,
        child: ElevatedButton.icon(
          onPressed: _connectToDevice,
          icon: const Icon(Icons.bluetooth),
          label: const Text("Connect"),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade600,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
      );
    }
  }

  Widget? _buildPlayPauseFab() {
    if (currentIndex != 1) return null;

    final isStreaming = feedScreenKey.currentState?.isStreaming ?? false;

    return FloatingActionButton(
      onPressed: () {
        if (isStreaming) {
          feedScreenKey.currentState?.stopStreaming();
        } else {
          feedScreenKey.currentState?.startStreaming();
        }
      },
      backgroundColor: isStreaming ? Colors.red.shade600 : Colors.teal.shade600,
      elevation: 4,
      child: Icon(
        isStreaming ? Icons.pause : Icons.play_arrow,
        color: Colors.white,
        size: 28,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    startForegroundService();
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Frame Vision',
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: Colors.blue.shade600,
            secondary: Colors.teal.shade600,
            surface: Colors.grey.shade900,
          ),
          appBarTheme: AppBarTheme(
            backgroundColor: Colors.grey.shade900,
            elevation: 2,
          ),
          bottomNavigationBarTheme: BottomNavigationBarThemeData(
            backgroundColor: Colors.grey.shade900,
            selectedItemColor: Colors.blue.shade400,
            unselectedItemColor: Colors.grey.shade500,
            elevation: 8,
          ),
        ),
        home: Scaffold(
          appBar: AppBar(
            title: Text(appBarTitles[currentIndex]),
            actions: [getBatteryWidget()],
          ),
          drawer: getCameraDrawer(),
          body: PageView(
            controller: pageController,
            onPageChanged: (index) async {
              if (currentIndex == 2 && index != 2) {
                // When leaving the settings page, fire an event
                EventService().fire(SettingsChangedEvent());
              }
              setState(() {
                currentIndex = index;
              });
              onRun();
            },
            children: <Widget>[
              PictureScreen(
                key: pictureScreenKey,
                frame: frame,
                capture: capture,
                isProcessing: isProcessing,
                setProcessing: _setProcessing,
                apiEndpoint: apiEndpoint,
              ),
              FeedScreen(
                key: feedScreenKey,
                frame: frame,
                capture: capture,
                isProcessing: isProcessing,
                setProcessing: _setProcessing,
                apiEndpoint: apiEndpoint,
                framesToQueue: framesToQueue,
                processFramesWithApi: processFramesWithApi,
              ),
              SettingsScreen(
                key: settingsScreenKey,
              ),
            ],
          ),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: BottomNavigationBar(
              currentIndex: currentIndex,
              onTap: (index) {
                pageController.animateToPage(
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
          ),
          floatingActionButton: _buildPlayPauseFab(),
          persistentFooterButtons: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: _buildConnectButton(),
            )
          ],
        ),
      ),
    );
  }

  void _startHeartbeatTimer() {
    heartbeatTimer?.cancel();
    heartbeatTimer = Timer.periodic(const Duration(seconds: 120), (timer) {
      // Instead of doing the work here, just fire an event.
      EventService().fire(HeartbeatEvent());
    });
  }
}