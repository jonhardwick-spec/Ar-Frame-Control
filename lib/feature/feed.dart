import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:collection';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:frame_msg/rx/auto_exp_result.dart' as FrameMsgRx;
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart' as VisionApp;
import 'package:frame_msg/tx/plain_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api_response_manager.dart'; // NEW

final _log = Logger("FeedScreen");

class FeedScreen extends StatefulWidget {
  final BrilliantDevice? frame;
  final Future<dynamic> Function() capture;
  final bool isProcessing;
  final Function(bool) setProcessing;
  final String apiEndpoint;
  final int framesToQueue;
  final bool processFramesWithApi;

  const FeedScreen({
    super.key,
    required this.frame,
    required this.capture,
    required this.isProcessing,
    required this.setProcessing,
    required this.apiEndpoint,
    required this.framesToQueue,
    required this.processFramesWithApi,
  });

  @override
  FeedScreenState createState() => FeedScreenState();
}

class FeedScreenState extends State<FeedScreen> {
  Image? _image;
  VisionApp.ImageMetadata? _imageMeta;
  final FrameMsgRx.RxAutoExpResult _rxAutoExpResult = FrameMsgRx.RxAutoExpResult();
  StreamSubscription<FrameMsgRx.AutoExpResult>? _autoExpResultSubs;
  FrameMsgRx.AutoExpResult? _autoExpResult;

  // Public getter for streaming status
  bool get isStreaming => _isStreaming;
  bool _isStreaming = false;

  final List<Uint8List> _capturedFrames = [];
  bool _isEncodingVideo = false;

  final Stopwatch _streamStopwatch = Stopwatch();
  final ListQueue<int> _frameTimestamps = ListQueue<int>();
  int _measuredFps = 10;

  // NEW: API Response Manager integration
  final ApiResponseManager _apiManager = ApiResponseManager();
  StreamSubscription<String>? _debugSubscription;
  StreamSubscription<ApiResponse>? _responseSubscription;
  final List<String> _debugMessages = [];
  final List<String> _apiResponseList = [];

  // NEW: AI Response waiting
  bool _waitingForAiResponse = false;
  bool _awaitAiResponseEnabled = false;

  @override
  void initState() {
    super.initState();
    _initializeApiManager();
  }

  @override
  void dispose() {
    _autoExpResultSubs?.cancel();
    _debugSubscription?.cancel();
    _responseSubscription?.cancel();
    if (_isStreaming) {
      stopStreaming();
    }
    _streamStopwatch.stop();
    super.dispose();
  }

  Future<void> _initializeApiManager() async {
    await _apiManager.initialize();

    // Listen to debug messages
    _debugSubscription = _apiManager.debugStream.listen((message) {
      if (mounted) {
        setState(() {
          _debugMessages.insert(0, message);
          if (_debugMessages.length > 50) {
            _debugMessages.removeLast();
          }
        });
      }
    });

    // Listen to API responses
    _responseSubscription = _apiManager.responseStream.listen((response) {
      if (mounted && response.success) {
        setState(() {
          _apiResponseList.insert(0, response.answer);
          if (_apiResponseList.length > 5) {
            _apiResponseList.removeLast();
          }
        });

        // Send response to Frame display
        _sendResponseToFrame(response.answer);

        // Reset waiting state
        _waitingForAiResponse = false;
      }
    });
  }

  Future<void> onRun() async {
    if (widget.frame == null) return;

    _autoExpResultSubs?.cancel();
    _autoExpResultSubs = _rxAutoExpResult.attach(widget.frame!.dataResponse).listen((autoExpResult) {
      if (mounted) {
        setState(() => _autoExpResult = autoExpResult);
      }
      _log.fine('auto exposure result: $autoExpResult');
    });

    await widget.frame!.sendMessage(0x0a, TxPlainText(text: '2-Tap: start or stop stream').pack());

    // Check server health
    await _apiManager.checkServerHealth();
  }

  Future<void> onCancel() async {
    _autoExpResultSubs?.cancel();
    stopStreaming();
  }

  Future<void> handleTap(int taps) async {
    if (taps == 2) {
      if (_isStreaming) {
        stopStreaming();
      } else {
        startStreaming();
      }
    }
  }

  Future<void> startStreaming() async {
    if (_isStreaming || widget.frame == null) return;
    _log.fine('Start streaming');
    if (!mounted) return;

    // Authenticate and update profile if processing with API
    if (widget.processFramesWithApi) {
      final authSuccess = await _apiManager.authenticate();
      if (!authSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to authenticate with server'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    setState(() {
      _isStreaming = true;
    });
    widget.setProcessing(true);
    _streamStopwatch.reset();
    _streamStopwatch.start();
    _frameTimestamps.clear();
    _apiResponseList.clear();
    _debugMessages.clear();

    while (_isStreaming) {
      try {
        if (!mounted) {
          stopStreaming();
          break;
        }

        // NEW: Wait for AI response before capturing next frame if enabled
        if (_awaitAiResponseEnabled && _waitingForAiResponse) {
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        var photo = await widget.capture();
        await process(photo);

        // NEW: If we're processing with API and awaiting responses, set waiting flag
        if (widget.processFramesWithApi && _awaitAiResponseEnabled) {
          _waitingForAiResponse = true;
        }

      } catch (e) {
        _log.severe('Error during streaming capture: $e');
        if(mounted){
          stopStreaming();
        }
        break;
      }
    }
  }

  void stopStreaming() {
    if (!_isStreaming) return;
    _log.fine('Stop streaming');
    if (mounted) {
      setState(() {
        _isStreaming = false;
        _waitingForAiResponse = false;
      });
      widget.setProcessing(false);
    }

    // Clear Frame display when stopping
    if (widget.frame != null) {
      widget.frame!.sendMessage(0x0a, TxPlainText(text: ' ').pack());
    }
  }

  Future<void> process((Uint8List, VisionApp.ImageMetadata) photo) async {
    if (!mounted || !_isStreaming) return;
    var imageData = photo.$1;
    var meta = photo.$2;
    setState(() {
      _image = Image.memory(imageData, gaplessPlayback: true);
      _imageMeta = meta;
      _capturedFrames.add(imageData);
      if (_capturedFrames.length > 300) {
        _capturedFrames.removeAt(0);
      }
    });

    // NEW: Process with API Response Manager
    if (widget.processFramesWithApi && !_apiManager.isProcessing) {
      // Process in background, don't await if not waiting for responses
      if (_awaitAiResponseEnabled) {
        await _apiManager.processImage(imageData);
      } else {
        _apiManager.processImage(imageData); // Fire and forget
      }
    }

    // Update FPS calculation
    if (_streamStopwatch.isRunning) {
      _frameTimestamps.addLast(_streamStopwatch.elapsedMilliseconds);
      if (_frameTimestamps.length > 30) {
        _frameTimestamps.removeFirst();
      }

      if (_frameTimestamps.length > 1) {
        int totalDiff = 0;
        for (int i = 0; i < _frameTimestamps.length - 1; i++) {
          totalDiff += _frameTimestamps.elementAt(i + 1) - _frameTimestamps.elementAt(i);
        }
        double averageMsPerFrame = totalDiff / (_frameTimestamps.length - 1);
        if (averageMsPerFrame > 0) {
          setState(() {
            _measuredFps = (1000 / averageMsPerFrame).round();
            if (_measuredFps == 0) _measuredFps = 1;
          });
        }
      }
    }
  }

  // Helper method to wrap text by characters
  List<String> _wrapTextByCharacters(String text, int maxCharsPerLine) {
    if (text.isEmpty) return [''];

    List<String> lines = [];
    List<String> words = text.split(' ');
    String currentLine = '';

    for (String word in words) {
      if (currentLine.isEmpty) {
        currentLine = word;
      } else if ((currentLine.length + 1 + word.length) <= maxCharsPerLine) {
        currentLine += ' $word';
      } else {
        lines.add(currentLine);
        currentLine = word;
      }
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    return lines;
  }

  // Send responses to the Frame
  Future<void> _sendResponseToFrame(String text) async {
    if (widget.frame == null || !_isStreaming) return;

    // Split the text into lines
    List<String> splitText = text.split('\n');

    // Wrap each line to fit within 24 characters
    List<String> wrappedLines = [];
    for (String line in splitText) {
      wrappedLines.addAll(_wrapTextByCharacters(line, 24));
    }

    // Take only the first 5 lines to avoid overwhelming the display
    if (wrappedLines.length > 5) {
      wrappedLines = wrappedLines.take(5).toList();
      wrappedLines.add('...');
    }

    try {
      // Send wrapped text to Frame display
      await widget.frame!.sendMessage(0x0a,
          TxPlainText(text: wrappedLines.join('\n')).pack()
      );
    } catch (e) {
      _log.warning("Failed to send response to Frame: $e");
    }
  }

  Future<void> _saveVideo() async {
    if (_capturedFrames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No frames captured yet. Start streaming first!')),
      );
      return;
    }

    if (_isEncodingVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video encoding already in progress.')),
      );
      return;
    }

    setState(() {
      _isEncodingVideo = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Preparing to encode ${_capturedFrames.length} frames at $_measuredFps FPS...')),
    );

    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String outputPath = '${tempDir.path}/live_feed_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

      final Completer<ui.Image> completer = Completer();
      ui.decodeImageFromList(_capturedFrames.first, completer.complete);
      final ui.Image firstImage = await completer.future;
      final int width = firstImage.width;
      final int height = firstImage.height;

      await FlutterQuickVideoEncoder.setup(
        width: width,
        height: height,
        fps: _measuredFps,
        videoBitrate: 2000000,
        audioChannels: 0,
        audioBitrate: 0,
        sampleRate: 0,
        filepath: outputPath,
        profileLevel: ProfileLevel.mainAutoLevel,
      );

      for (int i = 0; i < _capturedFrames.length; i++) {
        final Uint8List jpegBytes = _capturedFrames[i];
        final Completer<ui.Image> frameCompleter = Completer();
        ui.decodeImageFromList(jpegBytes, frameCompleter.complete);
        final ui.Image image = await frameCompleter.future;

        final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (byteData != null) {
          await FlutterQuickVideoEncoder.appendVideoFrame(byteData.buffer.asUint8List());
        } else {
          _log.warning('Failed to convert frame $i to RGBA.');
        }
      }

      await FlutterQuickVideoEncoder.finish();

      _log.info('Video created at $outputPath');
      final XFile videoFile = XFile(outputPath, mimeType: 'video/mp4');
      await Share.shareXFiles([videoFile], text: 'Live video from Brilliant Frame.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video saved successfully!')),
      );
    } catch (e, stack) {
      _log.severe('Error during video saving: $e\n$stack');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving video: $e')),
      );
    } finally {
      try {
        final Directory tempDir = await getTemporaryDirectory();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
          _log.info('Temporary directory cleaned up.');
        }
      } catch (e) {
        _log.warning('Failed to clean up temporary directory: $e');
      }
      _capturedFrames.clear();
      setState(() {
        _isEncodingVideo = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (_autoExpResult != null) AutoExpResultWidget(result: _autoExpResult!),
            const Divider(),

            // NEW: AI Response Control
            if (widget.processFramesWithApi) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.smart_toy, color: Colors.blue),
                          const SizedBox(width: 8),
                          Text('AI Response Control', style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        title: const Text('Await AI Response'),
                        subtitle: const Text('Wait for AI to respond before capturing next frame'),
                        value: _awaitAiResponseEnabled,
                        onChanged: (value) {
                          setState(() {
                            _awaitAiResponseEnabled = value;
                          });
                        },
                        secondary: Icon(_waitingForAiResponse ? Icons.hourglass_empty : Icons.check_circle),
                      ),
                      if (_waitingForAiResponse)
                        const LinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            _image ?? const Center(child: Padding(
              padding: EdgeInsets.all(32.0),
              child: Text("2-Tap to start stream", textAlign: TextAlign.center,),
            )),
            const Divider(),
            if (_imageMeta != null) VisionApp.ImageMetadataWidget(meta: _imageMeta!),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isStreaming && !_isEncodingVideo ? _saveVideo : null,
                    icon: _isEncodingVideo ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2) : const Icon(Icons.videocam),
                    label: Text(_isEncodingVideo ? 'Saving Video...' : 'Save Video'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _apiManager.checkServerHealth(),
                  icon: const Icon(Icons.health_and_safety),
                  label: const Text('Health'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (widget.processFramesWithApi) ...[
              // NEW: Debug Messages Panel
              Card(
                child: ExpansionTile(
                  title: Row(
                    children: [
                      Icon(Icons.bug_report, color: Colors.green),
                      const SizedBox(width: 8),
                      Text('Server Debug Messages (${_debugMessages.length})'),
                    ],
                  ),
                  children: [
                    Container(
                      height: 200,
                      padding: const EdgeInsets.all(8.0),
                      child: _debugMessages.isEmpty
                          ? const Center(child: Text('No debug messages yet'))
                          : ListView.builder(
                        itemCount: _debugMessages.length,
                        itemBuilder: (context, index) {
                          final message = _debugMessages[index];
                          Color textColor = Colors.white;
                          if (message.contains('✅')) textColor = Colors.green;
                          else if (message.contains('❌')) textColor = Colors.red;
                          else if (message.contains('⚠️')) textColor = Colors.orange;
                          else if (message.contains('🤖')) textColor = Colors.blue;

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Text(
                              message,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: textColor,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              const Text('AI Responses (Last 5):', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(5.0),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _apiResponseList.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Text(_apiResponseList[index], style: const TextStyle(fontSize: 12)),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AutoExpResultWidget extends StatelessWidget {
  final FrameMsgRx.AutoExpResult result;
  final TextStyle dataStyle = const TextStyle(fontSize: 10, fontFamily: 'monospace');

  const AutoExpResultWidget({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(5.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Error: ${result.error.toStringAsFixed(2)}', style: dataStyle),
              Text('Shutter: ${result.shutter.toInt()}', style: dataStyle),
              Text('AGain: ${result.analogGain.toInt()}', style: dataStyle),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('RGain: ${result.redGain.toStringAsFixed(2)}', style: dataStyle),
              Text('GGain: ${result.greenGain.toStringAsFixed(2)}', style: dataStyle),
              Text('BGain: ${result.blueGain.toStringAsFixed(2)}', style: dataStyle),
            ],
          ),
        ],
      ),
    );
  }
}