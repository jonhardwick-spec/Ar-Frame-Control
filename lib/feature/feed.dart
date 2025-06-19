import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:collection';
import 'dart:isolate'; // Import for Isolate communication

import 'package:flutter/material.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:frame_msg/rx/auto_exp_result.dart' as FrameMsgRx;
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart' as VisionApp;
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:share_plus/share_plus.dart';

import '../utilities/api_call.dart'; // Ensure ApiService is available
import '../utilities/frame_processing_isolate.dart'; // Import the new isolate file


final _log = Logger("FeedScreen");

class FeedScreen extends StatefulWidget {
  final BrilliantDevice? frame;
  final Future<dynamic> Function() capture;
  final bool isProcessing;
  final Function(bool) setProcessing;
  final String apiEndpoint; // API endpoint from settings
  final int framesToQueue; // Frames to queue from settings
  final bool processFramesWithApi; // New setting: control API processing

  const FeedScreen({
    super.key,
    required this.frame,
    required this.capture,
    required this.isProcessing,
    required this.setProcessing,
    required this.apiEndpoint,
    required this.framesToQueue,
    required this.processFramesWithApi, // New parameter
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
  bool _isStreaming = false;

  final List<Uint8List> _capturedFrames = [];
  bool _isEncodingVideo = false;

  final Stopwatch _streamStopwatch = Stopwatch();
  final ListQueue<int> _frameTimestamps = ListQueue<int>();
  int _measuredFps = 10;

  // Isolate related variables
  ReceivePort? _receivePort;
  SendPort? _isolateSendPort;
  Isolate? _frameProcessorIsolate;
  final List<String> _apiResponseList = []; // To display API responses

  @override
  void dispose() {
    _autoExpResultSubs?.cancel();
    if (_isStreaming) {
      stopStreaming();
    }
    _streamStopwatch.stop();
    _stopFrameProcessingIsolate(); // Stop the isolate on dispose
    super.dispose();
  }

  // Starts the frame processing isolate
  Future<void> _startFrameProcessingIsolate() async {
    _log.info("Starting frame processing isolate...");
    _receivePort = ReceivePort();
    _frameProcessorIsolate = await Isolate.spawn(
      frameProcessingEntryPoint,
      _receivePort!.sendPort,
    );

    _receivePort!.listen((dynamic message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        _isolateSendPort!.send(IsolateCommand(
          IsolateMessageType.settingsUpdate,
          data: {
            'apiEndpoint': widget.apiEndpoint,
            'framesToQueue': widget.framesToQueue,
            'processFramesWithApi': widget.processFramesWithApi, // Pass new setting
          },
        ));
      } else if (message is IsolateResponse) {
        switch (message.type) {
          case IsolateMessageType.result:
            _log.info("API response from isolate: ${message.data}");
            if (mounted) {
              setState(() {
                _apiResponseList.insert(0, message.data); // Add to top
                if (_apiResponseList.length > 5) { // Keep last 5 responses
                  _apiResponseList.removeLast();
                }
              });
            }
            break;
          case IsolateMessageType.error:
            _log.severe("Error from isolate: ${message.data}");
            if (mounted) {
              setState(() {
                _apiResponseList.insert(0, 'Isolate Error: ${message.data}');
                if (_apiResponseList.length > 5) {
                  _apiResponseList.removeLast();
                }
              });
            }
            break;
          default:
            _log.warning("Unknown response type from isolate: ${message.type}");
        }
      }
    });
  }

  // Stops the frame processing isolate
  void _stopFrameProcessingIsolate() {
    _isolateSendPort?.send(IsolateCommand(IsolateMessageType.stop));
    _receivePort?.close();
    _frameProcessorIsolate?.kill(priority: Isolate.immediate);
    _frameProcessorIsolate = null;
    _receivePort = null;
    _isolateSendPort = null;
    _log.info("Frame processing isolate stopped.");
  }


  @override
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

    // Update isolate settings whenever onRun is called (e.g., when page switches)
    if (_isolateSendPort != null) {
      _isolateSendPort!.send(IsolateCommand(
        IsolateMessageType.settingsUpdate,
        data: {
          'apiEndpoint': widget.apiEndpoint,
          'framesToQueue': widget.framesToQueue,
          'processFramesWithApi': widget.processFramesWithApi, // Pass new setting
        },
      ));
    }
  }

  @override
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

    // Start the isolate before starting the stream if API processing is enabled
    if (widget.processFramesWithApi) {
      await _startFrameProcessingIsolate();
    }


    setState(() {
      _isStreaming = true;
    });
    widget.setProcessing(true);
    _streamStopwatch.reset();
    _streamStopwatch.start();
    _frameTimestamps.clear();
    _apiResponseList.clear(); // Clear old responses

    while (_isStreaming) {
      try {
        if (!mounted) {
          stopStreaming();
          break;
        }
        var photo = await widget.capture();
        await process(photo);
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
      });
      widget.setProcessing(false);
    }
    _stopFrameProcessingIsolate(); // Stop the isolate when streaming stops (even if not started)
  }

  @override
  Future<void> process((Uint8List, VisionApp.ImageMetadata) photo) async {
    if (!mounted || !_isStreaming) return;
    var imageData = photo.$1;
    var meta = photo.$2;
    setState(() {
      _image = Image.memory(imageData, gaplessPlayback: true);
      _imageMeta = meta;
      _capturedFrames.add(imageData);
      if (_capturedFrames.length > 300) { // Limit stored frames for video saving
        _capturedFrames.removeAt(0);
      }
    });

    // Send frame to processing isolate only if API processing is enabled
    if (widget.processFramesWithApi && _isolateSendPort != null) {
      _isolateSendPort!.send(IsolateCommand(IsolateMessageType.processFrame, data: imageData));
    } else if (widget.processFramesWithApi && _isolateSendPort == null) {
      _log.warning("Isolate SendPort is null despite API processing being enabled. Frame not sent for processing.");
    } else {
      _log.fine("API processing disabled. Frame not sent for processing.");
    }

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
            _image ?? const Center(child: Padding(
              padding: EdgeInsets.all(32.0),
              child: Text("2-Tap to start stream", textAlign: TextAlign.center,),
            )),
            const Divider(),
            if (_imageMeta != null) VisionApp.ImageMetadataWidget(meta: _imageMeta!),
            const SizedBox(height: 20),
            ElevatedButton.icon(
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
            const SizedBox(height: 20),
            // Display API Responses (only if API processing is enabled)
            if (widget.processFramesWithApi) ...[
              const Text('API Responses (Last 5):', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(5.0),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(), // To prevent inner scrolling
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