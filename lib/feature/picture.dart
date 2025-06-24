import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:frame_ble/brilliant_device.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:frame_msg/tx/plain_text.dart';

import '../utilities/api_call.dart';

final log = Logger("PictureScreen");

class PictureScreen extends StatefulWidget {
  final BrilliantDevice? frame;
  final Future<dynamic> Function() capture;
  final bool isProcessing;
  final Function(bool) setProcessing;
  final String apiEndpoint;

  const PictureScreen({
    super.key,
    required this.frame,
    required this.capture,
    required this.isProcessing,
    required this.setProcessing,
    required this.apiEndpoint,
  });

  @override
  PictureScreenState createState() => PictureScreenState();
}

class PictureScreenState extends State<PictureScreen> {
  final List<Image> images = [];
  final List<Uint8List> imageDataList = [];
  final List<ImageMetadata> imageMetaList = [];
  final List<List<String>> responseTextLists = [];

  int currentImageIndex = 0;
  Timer? clearTimer;

  @override
  void dispose() {
    clearTimer?.cancel();
    super.dispose();
  }

  Future<void> onRun() async {
    if (widget.frame == null) return;
    await widget.frame!.sendMessage(0x0a,
        TxPlainText(text: '3-Tap: take photo').pack()
    );
  }

  Future<void> onCancel() async {
    if (!mounted) return;
    setState(() {
      images.clear();
      imageDataList.clear();
      imageMetaList.clear();
      responseTextLists.clear();
      currentImageIndex = 0;
    });
  }

  Future<void> handleTap(int taps) async {
    if (widget.frame == null || widget.isProcessing) return;

    if (taps == 3) {
      await capturePhoto();
    }
  }

  Future<void> capturePhoto() async {
    if (widget.frame == null || widget.isProcessing) return;

    widget.setProcessing(true);
    clearTimer?.cancel();
    clearTimer = null;

    await widget.frame!.sendMessage(0x0a,
        TxPlainText(text: '\u{F0007}', paletteOffset: 8).pack()
    );

    try {
      var photo = await widget.capture();
      await process(photo);
    } catch (e) {
      log.severe("Error capturing photo: $e");
      widget.setProcessing(false);
    }
  }

  Future<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;

    try {
      if (!mounted) return;
      setState(() {
        imageDataList.add(imageData);
        images.add(Image.memory(imageData, gaplessPlayback: true));
        imageMetaList.add(meta);
        responseTextLists.add([]);
        currentImageIndex = images.length - 1;
      });

      final apiService = ApiService(endpointUrl: widget.apiEndpoint);
      if (widget.frame != null) {
        await widget.frame!.sendMessage(0x0a,
            TxPlainText(text: '\u{F0003}', x: 285, y: 1, paletteOffset: 8).pack()
        );
      }

      final response = await apiService.processImage(imageBytes: imageData);
      await handleResponseText(response);

    } catch (e) {
      String err = 'Error: $e';
      log.severe(err);
      await handleResponseText(err);
    } finally {
      widget.setProcessing(false);
    }
  }

  Future<void> handleResponseText(String text) async {
    if (!mounted) return;

    // Split the text into lines first
    List<String> splitText = text.split('\n');

    // Wrap each line to fit within 24 characters
    List<String> wrappedLines = [];
    for (String line in splitText) {
      wrappedLines.addAll(_wrapTextByCharacters(line, 24));
    }

    setState(() {
      if (currentImageIndex < responseTextLists.length) {
        responseTextLists[currentImageIndex] = wrappedLines;
      }
    });

    if (widget.frame != null) {
      // Join wrapped lines with newlines for display on Frame
      await widget.frame!.sendMessage(0x0a,
          TxPlainText(text: wrappedLines.join('\n')).pack()
      );
    }
    scheduleClearDisplay();
  }

// Add this helper method to the PictureScreenState class
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

  void scheduleClearDisplay() {
    clearTimer?.cancel();
    clearTimer = Timer(const Duration(seconds: 10), () async {
      if (widget.frame != null && mounted && !widget.isProcessing) {
        await widget.frame!.sendMessage(0x0a, TxPlainText(text: ' ').pack());
      }
    });
  }

  void shareCurrentImage() {
    if (currentImageIndex < imageDataList.length && imageDataList.isNotEmpty) {
      final imageData = imageDataList[currentImageIndex];
      final responseText = currentImageIndex < responseTextLists.length
          ? responseTextLists[currentImageIndex].join('\n')
          : '';
      shareImage(imageData, responseText);
    }
  }

  static void shareImage(Uint8List? jpegBytes, String text) async {
    if (jpegBytes != null) {
      try {
        await Share.shareXFiles(
          [XFile.fromData(jpegBytes, mimeType: 'image/jpeg', name: 'image.jpg')],
          text: text,
        );
      } catch (e) {
        log.severe('Error sharing image: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (images.length > 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: currentImageIndex > 0
                      ? () {
                    setState(() {
                      currentImageIndex--;
                    });
                  }
                      : null,
                ),
                Text('Photo ${currentImageIndex + 1} of ${images.length}'),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: currentImageIndex < images.length - 1
                      ? () {
                    setState(() {
                      currentImageIndex++;
                    });
                  }
                      : null,
                ),
              ],
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              GestureDetector(
                onTap: shareCurrentImage,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: images.isNotEmpty && currentImageIndex < images.length
                            ? images[currentImageIndex]
                            : null,
                      ),
                    ),
                    if (imageMetaList.isNotEmpty && currentImageIndex < imageMetaList.length)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            children: [
                              ImageMetadataWidget(meta: imageMetaList[currentImageIndex]),
                              const Divider(),
                            ],
                          ),
                        ),
                      ),
                    if (responseTextLists.isNotEmpty &&
                        currentImageIndex < responseTextLists.length)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                              (context, index) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0),
                            child: Text(responseTextLists[currentImageIndex][index]),
                          ),
                          childCount: responseTextLists[currentImageIndex].length,
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton(
                  onPressed: widget.isProcessing ? null : capturePhoto,
                  backgroundColor: widget.isProcessing ? Colors.grey : Colors.blue,
                  child: widget.isProcessing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Icon(Icons.camera_alt, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}