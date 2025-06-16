import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:frame_msg/rx/auto_exp_result.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';

final _log = Logger("FeedScreen");

class FeedScreen extends StatefulWidget {
  final BrilliantDevice? frame;
  final Future<dynamic> Function() capture;
  final bool isProcessing;
  final Function(bool) setProcessing;

  const FeedScreen({
    super.key,
    required this.frame,
    required this.capture,
    required this.isProcessing,
    required this.setProcessing,
  });

  @override
  FeedScreenState createState() => FeedScreenState();
}

class FeedScreenState extends State<FeedScreen> {
  Image? _image;
  ImageMetadata? _imageMeta;
  final RxAutoExpResult _rxAutoExpResult = RxAutoExpResult();
  StreamSubscription<AutoExpResult>? _autoExpResultSubs;
  AutoExpResult? _autoExpResult;
  bool _isStreaming = false;

  @override
  void dispose() {
    _autoExpResultSubs?.cancel();
    // Ensure streaming is stopped when the widget is disposed
    if (_isStreaming) {
      stopStreaming();
    }
    super.dispose();
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

    setState(() {
      _isStreaming = true;
    });
    widget.setProcessing(true);

    while (_isStreaming) {
      try {
        if (!mounted) {
          stopStreaming();
          break;
        }
        var photo = await widget.capture();
        await process(photo);
        // Add a small delay to prevent spamming captures too quickly and to allow UI to update
        await Future.delayed(const Duration(milliseconds: 100));
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
  }

  Future<void> process((Uint8List, ImageMetadata) photo) async {
    if (!mounted || !_isStreaming) return;
    var imageData = photo.$1;
    var meta = photo.$2;
    setState(() {
      _image = Image.memory(imageData, gaplessPlayback: true);
      _imageMeta = meta;
    });
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
            if (_imageMeta != null) ImageMetadataWidget(meta: _imageMeta!),
          ],
        ),
      ),
    );
  }
}

class AutoExpResultWidget extends StatelessWidget {
  final AutoExpResult result;
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
