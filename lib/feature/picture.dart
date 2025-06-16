import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';

import '../api_call.dart';
import '../text_pagination.dart';

final _log = Logger("PictureScreen");

class PictureScreen extends StatefulWidget {
  final BrilliantDevice? frame;
  final Future<dynamic> Function() capture;
  final bool isProcessing;
  final Function(bool) setProcessing;

  const PictureScreen({
    super.key,
    required this.frame,
    required this.capture,
    required this.isProcessing,
    required this.setProcessing,
  });

  @override
  PictureScreenState createState() => PictureScreenState();
}

class PictureScreenState extends State<PictureScreen> {
  String _apiEndpoint = '';
  final TextEditingController _apiEndpointTextFieldController = TextEditingController();

  Image? _image;
  Uint8List? _imageData;
  ImageMetadata? _imageMeta;

  Timer? _clearTimer;
  final List<String> _responseTextList = [];
  final TextPagination _pagination = TextPagination();

  @override
  void initState() {
    super.initState();
    _loadApiEndpoint();
  }

  @override
  void dispose() {
    _apiEndpointTextFieldController.dispose();
    _clearTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadApiEndpoint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _apiEndpoint = prefs.getString('api_endpoint') ?? '';
      _apiEndpointTextFieldController.text = _apiEndpoint;
    });
  }

  Future<void> _saveApiEndpoint() async {
    _apiEndpoint = _apiEndpointTextFieldController.text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_endpoint', _apiEndpoint);
  }

  Future<void> onRun() async {
    if (widget.frame == null) return;
    await widget.frame!.sendMessage(0x0a,
        TxPlainText(
            text: '3-Tap: take photo\n______________\n1-Tap: next page\n2-Tap: previous page'
        ).pack()
    );
  }

  Future<void> onCancel() async {
    if (!mounted) return;
    setState(() {
      _responseTextList.clear();
      _pagination.clear();
    });
  }

  Future<void> handleTap(int taps) async {
    if (widget.frame == null || widget.isProcessing) return;

    switch (taps) {
      case 1: // Next Page
        _clearTimer?.cancel();
        _clearTimer = null;
        _pagination.nextPage();
        await widget.frame!.sendMessage(0x0a,
            TxPlainText(text: _pagination.getCurrentPage().join('\n')).pack()
        );
        setState((){});
        break;
      case 2: // Previous Page
        _clearTimer?.cancel();
        _clearTimer = null;
        _pagination.previousPage();
        await widget.frame!.sendMessage(0x0a,
            TxPlainText(text: _pagination.getCurrentPage().join('\n')).pack()
        );
        setState((){});
        break;
      case 3: // Take Photo
        widget.setProcessing(true);
        _clearTimer?.cancel();
        _clearTimer = null;

        await widget.frame!.sendMessage(0x0a,
            TxPlainText(text: '\u{F0007}', paletteOffset: 8).pack() // starry eyes emoji
        );

        try {
          var photo = await widget.capture();
          await process(photo);
        } catch (e) {
          _log.severe("Error capturing photo: $e");
          widget.setProcessing(false);
        }
        break;
    }
  }

  Future<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;

    try {
      if (!mounted) return;
      setState(() {
        _imageData = imageData;
        _image = Image.memory(imageData, gaplessPlayback: true);
        _imageMeta = meta;
        _responseTextList.clear();
      });

      final apiService = ApiService(endpointUrl: _apiEndpoint);
      if (widget.frame != null) {
        await widget.frame!.sendMessage(0x0a,
            TxPlainText(text: '\u{F0003}', x: 285, y: 1, paletteOffset: 8).pack() // 3d shades emoji
        );
      }

      final response = await apiService.processImage(imageBytes: imageData);
      await _handleResponseText(response);

    } catch (e) {
      String err = 'Error: $e';
      _log.severe(err);
      await _handleResponseText(err);
    } finally {
      widget.setProcessing(false);
    }
  }

  Future<void> _handleResponseText(String text) async {
    if (!mounted) return;
    _responseTextList.clear();
    _pagination.clear();
    List<String> splitText = text.split('\n');

    setState(() {
      _responseTextList.addAll(splitText);
      for (var line in splitText) {
        _pagination.appendLine(line);
      }
    });

    if (widget.frame != null) {
      await widget.frame!.sendMessage(0x0a,
          TxPlainText(text: _pagination.getCurrentPage().join('\n')).pack()
      );
    }
    _scheduleClearDisplay();
  }

  void _scheduleClearDisplay() {
    _clearTimer?.cancel();
    _clearTimer = Timer(const Duration(seconds: 10), () async {
      if (widget.frame != null && mounted && !widget.isProcessing) {
        await widget.frame!.sendMessage(0x0a, TxPlainText(text: ' ').pack());
      }
    });
  }

  static void _shareImage(Uint8List? jpegBytes, String text) async {
    if (jpegBytes != null) {
      try {
        await Share.shareXFiles(
          [XFile.fromData(jpegBytes, mimeType: 'image/jpeg', name: 'image.jpg')],
          text: text,
        );
      } catch (e) {
        _log.severe('Error sharing image: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _apiEndpointTextFieldController,
                  decoration: const InputDecoration(
                    hintText: 'E.g. http://192.168.0.5:8000/process',
                  ),
                ),
              ),
              ElevatedButton(onPressed: _saveApiEndpoint, child: const Text('Save')),
            ],
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () => _shareImage(_imageData, _responseTextList.join('\n')),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _image,
                  ),
                ),
                if (_imageMeta != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          ImageMetadataWidget(meta: _imageMeta!),
                          const Divider(),
                        ],
                      ),
                    ),
                  ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                        (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(_responseTextList[index]),
                    ),
                    childCount: _responseTextList.length,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
